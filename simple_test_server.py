import http.server
import socketserver
import cgi
import json
import sys
import os

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from app.services.ocr.pipeline import run_ocr_pipeline

PORT = 8081

html_content = """
<!DOCTYPE html>
<html>
    <head>
        <title>처방전 OCR 임시 테스트기</title>
        <meta charset="utf-8">
        <style>
            body { font-family: 'Malgun Gothic', sans-serif; padding: 30px; background: #f0f4f8; }
            .container { max-width: 600px; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.1); }
            h2 { color: #2c3e50; margin-top: 0; }
            input[type="file"] { margin: 20px 0; font-size: 16px; }
            button { background: #4CAF50; color: white; padding: 12px 24px; border: none; border-radius: 8px; cursor: pointer; font-size: 16px; font-weight: bold; }
            button:hover { background: #45a049; }
        </style>
    </head>
    <body>
        <div class="container">
            <h2>💊 처방전 OCR (Gemini) 임시 테스트</h2>
            <p>앱(Flutter)과 상관없이 PC에서 사진을 올려서 제미나이가 처방전을 어떻게 읽어내는지 직관적으로 테스트하는 페이지입니다.</p>
            <form action="/upload" method="post" enctype="multipart/form-data">
                <input type="file" name="file" accept="image/*" required>
                <br>
                <button type="submit">사진 업로드하고 분석하기</button>
            </form>
        </div>
    </body>
</html>
"""

class OCRTestHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header("Content-type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(html_content.encode("utf-8"))
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == '/upload':
            content_type = self.headers.get('Content-Type')
            if not content_type:
                self.send_error(400, "Bad Request")
                return
            
            form = cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={'REQUEST_METHOD': 'POST', 'CONTENT_TYPE': content_type}
            )
            
            if 'file' not in form:
                self.send_error(400, "No file uploaded")
                return
            
            file_item = form['file']
            file_data = file_item.file.read()
            base64_str = base64.b64encode(file_data).decode("utf-8")
            
            try:
                result = run_ocr_pipeline(file_data)
                json_str = json.dumps(
                    {
                        "ok": result.ok,
                        "raw_text": result.raw_text,
                        "structured": result.structured,
                        "error": result.error,
                        "trace": result.trace,
                    },
                    ensure_ascii=False,
                    indent=4,
                )
            except Exception as e:
                import traceback
                json_str = f"분석 중 상세 오류 발생:\\n{traceback.format_exc()}"

            result_html = f"""
            <!DOCTYPE html>
            <html>
                <head><meta charset="utf-8"><title>분석 결과</title></head>
                <body style="font-family: 'Malgun Gothic', sans-serif; padding: 30px; background: #f0f4f8;">
                    <div style="max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 12px rgba(0,0,0,0.1);">
                        <h2 style="color: #2c3e50; margin-top: 0;">✅ Gemini AI 분석 결과</h2>
                        <p>제미나이가 사진을 읽고 아래와 같이 정확하게 파싱했습니다:</p>
                        <pre style="background: #2c3e50; color: #ecf0f1; padding: 15px; border-radius: 8px; overflow-x: auto; font-size: 16px; line-height: 1.5;">{json_str}</pre>
                        <br>
                        <a href="/" style="display: inline-block; background: #3498db; color: white; padding: 12px 24px; text-decoration: none; border-radius: 8px; font-weight: bold;">돌아가기 (다른 사진 테스트)</a>
                    </div>
                </body>
            </html>
            """
            
            self.send_response(200)
            self.send_header("Content-type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(result_html.encode("utf-8"))

if __name__ == "__main__":
    with socketserver.TCPServer(("", PORT), OCRTestHandler) as httpd:
        print(f"임시 테스트 서버가 포트 {PORT}에서 실행 중입니다...")
        print("웹 브라우저에서 http://localhost:8081 에 접속하세요.")
        httpd.serve_forever()
