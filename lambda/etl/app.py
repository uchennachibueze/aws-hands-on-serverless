import json
import os

import boto3

s3 = boto3.client("s3")

CURATED_BUCKET = os.environ["CURATED_BUCKET"]


def handler(event, context):
    """Triggered by S3 ObjectCreated events on the raw bucket."""
    for record in event.get("Records", []):
        src_bucket = record["s3"]["bucket"]["name"]
        src_key = record["s3"]["object"]["key"]

        obj = s3.get_object(Bucket=src_bucket, Key=src_key)
        raw = json.loads(obj["Body"].read().decode("utf-8"))

        payload = raw.get("payload", {})

        curated = {
            "eventId": raw.get("eventId"),
            "receivedAt": raw.get("receivedAt"),
            "type": payload.get("type", "unknown"),
            "userId": payload.get("userId", "anonymous"),
            "data": payload.get("data", {}),
        }

        # Mirror path into curated bucket
        dst_key = src_key.replace("events/", "curated/events/", 1)

        s3.put_object(
            Bucket=CURATED_BUCKET,
            Key=dst_key,
            Body=json.dumps(curated).encode("utf-8"),
            ContentType="application/json",
        )

    return {"ok": True}
