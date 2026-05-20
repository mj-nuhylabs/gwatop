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
    # NOTE: ContentType은 서명 파라미터에 포함하지 않는다.
    # 포함하면 클라이언트가 보내는 Content-Type 헤더와 1바이트라도 다르면
    # SignatureDoesNotMatch (400/403)로 실패한다. iOS URLSession이 자동으로
    # 헤더를 살짝 바꾸는 경우가 있어 호환성을 위해 빼는 게 안전.
    return _client().generate_presigned_url(
        "put_object",
        Params={"Bucket": settings.S3_BUCKET_NAME, "Key": storage_key},
        ExpiresIn=3600,
    )


def get_public_url(storage_key: str) -> str:
    return f"https://{settings.S3_BUCKET_NAME}.s3.{settings.AWS_REGION}.amazonaws.com/{storage_key}"


def download_to_bytes(storage_key: str) -> bytes:
    obj = _client().get_object(Bucket=settings.S3_BUCKET_NAME, Key=storage_key)
    return obj["Body"].read()


# hyunnow의 pdf_tasks.py에서 import 하는 이름과 호환되도록 별칭 제공.
download_object_bytes = download_to_bytes
