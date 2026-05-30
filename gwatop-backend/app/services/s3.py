import uuid
import boto3
from botocore.config import Config
from app.core.config import settings


def _client():
    # ap-northeast-2 등 최신 리전은 SigV4 필수. 기본값이 V2로 떨어질 때가
    # 있어 명시적으로 s3v4를 지정해야 presigned URL이 받아들여진다.
    return boto3.client(
        "s3",
        region_name=settings.AWS_REGION,
        aws_access_key_id=settings.AWS_ACCESS_KEY_ID,
        aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY,
        config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
    )


def build_storage_key(user_id: str, filename: str) -> str:
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else "bin"
    return f"users/{user_id}/files/{uuid.uuid4()}.{ext}"


def generate_presigned_put_url(storage_key: str, content_type: str = "application/octet-stream") -> str:
    return _client().generate_presigned_url(
        "put_object",
        Params={
            "Bucket": settings.S3_BUCKET_NAME,
            "Key": storage_key,
            "ContentType": content_type,
        },
        ExpiresIn=3600,
    )


def get_public_url(storage_key: str) -> str:
    return f"https://{settings.S3_BUCKET_NAME}.s3.{settings.AWS_REGION}.amazonaws.com/{storage_key}"


def download_to_bytes(storage_key: str) -> bytes:
    obj = _client().get_object(Bucket=settings.S3_BUCKET_NAME, Key=storage_key)
    return obj["Body"].read()


def head_object(storage_key: str) -> dict:
    return _client().head_object(Bucket=settings.S3_BUCKET_NAME, Key=storage_key)


def delete_object(storage_key: str) -> None:
    _client().delete_object(Bucket=settings.S3_BUCKET_NAME, Key=storage_key)


def generate_presigned_get_url(storage_key: str, expires_in: int = 3600) -> str:
    """iOS 등 클라이언트가 S3에서 직접 다운로드(또는 PDFKit으로 inline 로드)할 수 있게
    하는 일회용 URL. 기본 1시간."""
    return _client().generate_presigned_url(
        "get_object",
        Params={"Bucket": settings.S3_BUCKET_NAME, "Key": storage_key},
        ExpiresIn=expires_in,
    )
