import uuid
import boto3
from app.core.config import settings


def _client():
    return boto3.client(
        "s3",
        region_name=settings.AWS_REGION,
        aws_access_key_id=settings.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY,
    )


def build_storage_key(user_id: str, filename: str) -> str:
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else "bin"
    return f"users/{user_id}/files/{uuid.uuid4()}.{ext}"


def generate_presigned_put_url(storage_key: str, content_type: str = "application/octet-stream") -> str:
    return _client().generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.S3_BUCKET_NAME, "Key": storage_key, "ContentType": content_type},
        ExpiresIn=3600,
    )


def get_public_url(storage_key: str) -> str:
    return f"https://{settings.S3_BUCKET_NAME}.s3.{settings.AWS_REGION}.amazonaws.com/{storage_key}"
