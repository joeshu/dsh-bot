#!/usr/bin/env python3
"""Verify the official search adapter without sending requests or using real credentials."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile

spec = importlib.util.spec_from_file_location("dsbot_smoke", Path(__file__).with_name("smoke-dsh-runtime.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


FETCH_FIXTURE = r"""
import { appendFileSync } from 'node:fs'
const log = (row) => appendFileSync(process.env.DSBOT_SEARCH_PROBE_LOG, JSON.stringify(row) + '\n')
globalThis.fetch = async (input, init) => {
  const url = new URL(typeof input === 'object' ? input.url : input)
  if (url.origin !== 'https://api.deepseek.com') throw new Error('Unexpected fixture origin')
  const request = JSON.parse(init.body)
  if (url.pathname === '/v1/tools/search') {
    if (new Headers(init.headers).get('authorization') !== 'Bearer fixture-key' || init.redirect !== 'error') {
      throw new Error('Unexpected fixture authentication or redirect mode')
    }
    log({ kind: 'search', request })
    return Response.json({ results: [
      { url: 'https://example.com/search-fixture', title: 'Fixture result', snippet: 'Fixture excerpt', date: null },
    ] })
  }
  if (!url.pathname.endsWith('/messages')) throw new Error('Unexpected fixture endpoint')
  const blocks = request.messages.flatMap((message) => Array.isArray(message.content) ? message.content : [])
  const label = blocks.find((block) => block.type === 'text' && block.text.startsWith('fixture human prompt:'))?.text
  const result = blocks.find((block) => block.type === 'tool_result')
  const toolNames = request.tools?.map((tool) => tool.name) ?? []
  log({ kind: 'model', label, toolNames, result })
  const useTool = !result && toolNames.includes('web_search')
  const event = (type, fields = {}) => 'event: ' + type + '\ndata: ' + JSON.stringify({ type, ...fields }) + '\n\n'
  return new Response([
    event('message_start', { message: { id: 'fixture-message', type: 'message', role: 'assistant',
      content: [], model: request.model, stop_reason: null, usage: { input_tokens: 5, output_tokens: 0 } } }),
    event('content_block_start', { index: 0, content_block: useTool
      ? { type: 'tool_use', id: 'fixture-tool', name: 'web_search', input: {} }
      : { type: 'text', text: '' } }),
    event('content_block_delta', { index: 0, delta: useTool
      ? { type: 'input_json_delta', partial_json: JSON.stringify({ queries: ['DSH fixture query'] }) }
      : { type: 'text_delta', text: 'Fixture completed' } }),
    event('content_block_stop', { index: 0 }),
    event('message_delta', { delta: { stop_reason: useTool ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 6 } }),
    event('message_stop'),
  ].join(''), { headers: { 'content-type': 'text/event-stream' } })
}
"""


def main():
    with tempfile.TemporaryDirectory(prefix="dsbot-web-search-") as temporary:
        directory = Path(temporary)
        fixture = directory / "fetch.mjs"
        fixture.write_text(FETCH_FIXTURE)
        log = directory / "requests.jsonl"
        os.environ["NODE_OPTIONS"] = f"--import={fixture.as_uri()}"
        os.environ["DSBOT_SEARCH_PROBE_LOG"] = str(log)
        node = shutil.which("node")
        assert node, "Node.js is required"
        peer, process = smoke.start_runtime(node, directory, directory / "sessions.sqlite")
        expected_approval = None
        approvals = []
        completed_events = []
        original = peer.answer_runtime
        original_wait = peer.wait_for_chat_done

        def wait_for_chat_done():
            if completed_events:
                return completed_events.pop(0)
            return original_wait()

        peer.wait_for_chat_done = wait_for_chat_done

        def answer(message):
            if message.get('method') is None:
                return
            method = message.get("method")
            if method == "chat.done":
                completed_events.append(message.get("params", {}))
                return
            if method == "approval.request":
                params = message["params"]
                assert params["tool"] == "web_search", params
                assert params["turnId"] == expected_approval, params
                assert "DSH fixture query" in params["summary"] and "fixture human prompt" not in params["summary"], params
                approvals.append(params)
                response_id = peer.next_id
                peer.next_id += 1
                peer.send({"jsonrpc": "2.0", "id": response_id, "method": "approval.respond", "params": {
                    "approvalId": params["approvalId"], "turnId": params["turnId"],
                    "sessionId": params["sessionId"], "approved": expected_approval == "allowed",
                }})
                return
            elif method == "credential.resolve":
                result = {"value": "fixture-key"}
            elif method == "credential.describe":
                result = {"configured": True}
            else:
                return original(message)
            peer.send({"jsonrpc": "2.0", "id": message["id"], "result": result})

        peer.answer_runtime = answer
        try:
            peer.start()
            peer.request("runtime.config.update", {
                "webSearchCount": 5, "webSearchSendOriginalQuestion": False,
            })
            for label, enabled in (("off", False), ("denied", True), ("allowed", True)):
                expected_approval = label
                peer.request("chat.send", {
                    "sessionId": label, "turnId": label, "model": "deepseek-flash",
                    "apiBaseURL": "https://api.deepseek.com", "text": f"fixture human prompt:{label}",
                    "webSearchEnabled": enabled,
                })
                result = peer.wait_for_chat_done()
                assert result["status"] == "completed", result
                entries = [json.loads(row) for row in log.read_text().splitlines()]
                requests = [row for row in entries if row["kind"] == "search"]
                if label != "allowed":
                    assert not requests, "Search sent without approval"

            off = next(row for row in entries if row.get("label") == "fixture human prompt:off")
            assert "web_search" not in off["toolNames"]
            assert [row["turnId"] for row in approvals] == ["denied", "allowed"], approvals
            assert len(requests) == 1
            assert requests[0]["request"] == {
                "query": "DSH fixture query", "count": 5, "need_content": False,
            }, requests
            assert any("https://example.com/search-fixture" in json.dumps(row.get("result")) for row in entries)
            print("DeepSeek search passed: opt-in visibility, denial without network, bounded approved query, no original prompt")
        finally:
            smoke.stop_runtime(peer, process)


if __name__ == "__main__":
    main()
