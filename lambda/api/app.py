import base64
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

TABLE_NAME = os.environ["TABLE_NAME"]
RAW_BUCKET = os.environ["RAW_BUCKET"]

table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    """HTTP API (v2) Lambda proxy handler."""
    method = (
        (event.get("requestContext", {}).get("http", {}).get("method") or "")
        .upper()
    )

    # Handle CORS preflight
    if method == "OPTIONS":
        return resp(204, "")

    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")

    try:
        payload = json.loads(body) if body else {}
    except json.JSONDecodeError:
        return resp(400, {"message": "Invalid JSON body"})

    event_type = payload.get("type", "unknown")
    user_id = payload.get("userId", "anonymous")

    now = datetime.now(timezone.utc)
    iso = now.isoformat()
    event_id = str(uuid.uuid4())

    pk = f"USER#{user_id}"
    sk = f"TS#{iso}#{event_id}"
    raw_key = f"events/userId={user_id}/dt={now.date()}/{event_id}.json"

    # Cost control: keep item small; TTL auto-expires in 30 days
    item = {
        "pk": pk,
        "sk": sk,
        "eventId": event_id,
        "type": event_type,
        "createdAt": iso,
        "rawS3Key": raw_key,
        "ttl": int(now.timestamp()) + 30 * 24 * 3600,
    }

    table.put_item(Item=item)

    raw_obj = {"eventId": event_id, "receivedAt": iso, "payload": payload}
    s3.put_object(
        Bucket=RAW_BUCKET,
        Key=raw_key,
        Body=json.dumps(raw_obj).encode("utf-8"),
        ContentType="application/json",
    )

    return resp(201, {"message": "Stored", "eventId": event_id, "rawKey": raw_key})


def resp(status, body):
    return {
        "statusCode": status,
        "headers": {
            "content-type": "application/json",
            "access-control-allow-origin": "*",
            "access-control-allow-methods": "GET,POST,OPTIONS",
            "access-control-allow-headers": "content-type,authorization",
        },
        "body": body if isinstance(body, str) else json.dumps(body),
    }
