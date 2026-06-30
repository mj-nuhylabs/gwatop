import uuid
import boto3
from botocore.config import Config
from app.core.config import settings


# boto3 client 는 요청에 대해 스레드 안전 → 프로세스당 1회만 만들고 재사용한다.
# (매 호출 생성 시 자격증명 재해석 + 새 연결 풀 구성 → 다운로드/프리사인마다 낭비.)
_s3_client = None


def _client():
    # ap-northeast-2 등 최신 리전은 SigV4 필수. 기본값이 V2로 떨어질 때가
    # 있어 명시적으로 s3v4를 지정해야 presigned URL이 받아들여진다.
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client(
            "s3",
            region_name=settings.AWS_REGION,
            aws_access_key_id=settings.AWS_ACCESS_KEY_ID,
            aws_secret_access_key=settings.AWS_SECRET_ACCESS_KEY,
            config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
        )
    return _s3_client


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


# ---------- 멀티파트 업로드 ----------
# 대용량(수십~수백 MB) 파일을 단일 PUT 으로 올리면 전송 중 연결이 끊겨 통째로 실패한다
# (브라우저 net::ERR_FAILED). 파일을 여러 파트로 쪼개 각각 presigned 로 올리고, 실패한
# 파트만 재시도한 뒤 complete 로 합친다. 객체의 최종 ContentType 은 create 시점에 고정된다.


def create_multipart_upload(
    storage_key: str, content_type: str = "application/octet-stream"
) -> str:
    """멀티파트 업로드를 시작하고 UploadId 를 반환한다."""
    resp = _client().create_multipart_upload(
        Bucket=settings.S3_BUCKET_NAME,
        Key=storage_key,
        ContentType=content_type,
    )
    return resp["UploadId"]


def generate_presigned_upload_part_url(
    storage_key: str, upload_id: str, part_number: int, expires_in: int = 3600
) -> str:
    """특정 파트(part_number, 1-base)를 PUT 할 presigned URL.

    ContentType 을 서명에 포함하지 않으므로(SignedHeaders=host) 브라우저가 보내는
    Content-Type 은 무시된다 — 파트마다 헤더를 맞출 필요가 없다.
    """
    return _client().generate_presigned_url(
        "upload_part",
        Params={
            "Bucket": settings.S3_BUCKET_NAME,
            "Key": storage_key,
            "UploadId": upload_id,
            "PartNumber": part_number,
        },
        ExpiresIn=expires_in,
    )


def complete_multipart_upload(
    storage_key: str, upload_id: str, parts: list[dict]
) -> dict:
    """파트들을 합쳐 하나의 객체로 확정한다.

    parts: [{"PartNumber": int, "ETag": str}, ...] — PartNumber 오름차순이어야 한다.
    """
    return _client().complete_multipart_upload(
        Bucket=settings.S3_BUCKET_NAME,
        Key=storage_key,
        UploadId=upload_id,
        MultipartUpload={"Parts": parts},
    )


def abort_multipart_upload(storage_key: str, upload_id: str) -> None:
    """진행 중인 멀티파트 업로드를 취소해 부분 업로드된 파트를 정리한다(과금 방지)."""
    _client().abort_multipart_upload(
        Bucket=settings.S3_BUCKET_NAME,
        Key=storage_key,
        UploadId=upload_id,
    )
