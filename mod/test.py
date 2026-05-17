import json
import sys


def error_response(request_id, code, message):
    return {
        "jsonrpc": "2.0",
        "error": {"code": code, "message": message},
        "id": request_id,
    }


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        print(json.dumps(error_response(None, -32700, "Parse error"), separators=(',', ':')), flush=True)
        continue

    request_id = msg.get("id")
    params = msg.get("params")

    if msg.get("method") == "message.received" and isinstance(params, dict):
        history = params.get("messages", [])
        if not isinstance(history, list):
            response = error_response(request_id, -32602, "Invalid params")
            print(f"received from zig: {msg!r}", file=sys.stderr, flush=True)
            print(json.dumps(response, separators=(',', ':')), flush=True)
            continue

        latest_user = next(
            (
                item.get("content", "")
                for item in reversed(history)
                if isinstance(item, dict) and item.get("role") == "user"
            ),
            "",
        )
        response = {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": f"Python received {len(history)} session messages. Latest user: {latest_user}",
        }
    else:
        response = error_response(request_id, -32601, "Method not found")

    print(f"received from zig: {msg!r}", file=sys.stderr, flush=True)

    print(json.dumps(response, separators=(',', ':')), flush=True)
