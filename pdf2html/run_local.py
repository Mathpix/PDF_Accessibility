# run_local.py
import os, json, shutil
from types import SimpleNamespace

# aws s3 cp /Users/olgaredozubova/Rab/MATHPIX/monorepo/ocr-api/mathpix/mmd-converter/examples/node/mmd/14-OpenAI.html.zip s3://pdf2html-bucket-426887012336-us-east-1/uploads/14-OpenAI.html.zip
SOURCE_PDF_PATH = os.environ.get("SOURCE_PDF_PATH", "14-OpenAI.html.zip")
OUTPUT_DIR = os.environ.get("OUTPUT_DIR", "./out")

os.environ["LOCAL_MODE"] = "true"
os.environ["SOURCE_PDF_PATH"] = SOURCE_PDF_PATH
os.environ["OUTPUT_DIR"] = OUTPUT_DIR

from lambda_function import lambda_handler

if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    ctx = SimpleNamespace(aws_request_id="local-001")
    event = {"Records":[{"s3":{"bucket":{"name":"pdf2html-bucket-426887012336-us-east-1"},"object":{"key":"uploads/"+os.path.basename(SOURCE_PDF_PATH)}}}]}
    res = lambda_handler(event, ctx)
    print(json.dumps(res, ensure_ascii=False, indent=2))
