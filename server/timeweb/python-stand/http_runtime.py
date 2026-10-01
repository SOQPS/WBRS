"""Bounded WSGI workers for this single-instance Timeweb stand.

Slow body/DB calls cannot serialize every API request. No request URL, token,
body or database exception is logged. Hosting TLS terminates upstream.
"""
import socket
import threading
from socketserver import ThreadingMixIn
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, ServerHandler, make_server


class QuietServerHandler(ServerHandler):
    def log_exception(self, exc_info):
        # wsgiref otherwise prints the application's exception and traceback,
        # independently of RequestHandler.log_message/Server.handle_error.
        pass


class QuietRequestHandler(WSGIRequestHandler):
    def log_message(self, *args):
        pass

    def get_environ(self):
        environ = super().get_environ()
        environ["wsgi.multithread"] = True
        return environ

    def handle(self):
        self.raw_requestline = self.rfile.readline(65537)
        if len(self.raw_requestline) > 65536:
            self.requestline = ""; self.request_version = ""; self.command = ""
            self.send_error(414)
            return
        if not self.parse_request():
            return
        handler = QuietServerHandler(self.rfile, self.wfile, self.get_stderr(),
                                     self.get_environ(), multithread=True)
        handler.request_handler = self
        handler.run(self.server.get_app())


class BoundedWSGIServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True
    request_queue_size = 16
    MAX_WORKERS = 8
    SOCKET_TIMEOUT_SECONDS = 10
    REQUEST_DEADLINE_SECONDS = 10

    def __init__(self, *args, **kwargs):
        self._slots = threading.BoundedSemaphore(self.MAX_WORKERS)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        request.settimeout(self.SOCKET_TIMEOUT_SECONDS)
        if not self._slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Content-Type: application/json\r\nCache-Control: no-store\r\n"
                    b"Connection: close\r\nRetry-After: 1\r\nContent-Length: 31\r\n\r\n"
                    b'{"error":"service_unavailable"}')
            except (OSError, socket.timeout):
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            self.shutdown_request(request)

    def process_request_thread(self, request, client_address):
        # A socket inactivity timeout alone permits an endless trickle of
        # bytes. An absolute deadline closes headers/body/response regardless
        # of that trickle; it never launches or retries an application write.
        watchdog = threading.Timer(self.REQUEST_DEADLINE_SECONDS, self._expire,
                                   args=(request,))
        watchdog.daemon = True
        try:
            watchdog.start()
            super().process_request_thread(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
            self.shutdown_request(request)
        finally:
            watchdog.cancel()
            self._slots.release()

    @staticmethod
    def _expire(request):
        try:
            request.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def handle_error(self, request, client_address):
        # Never send a traceback or exception to public logs.
        pass


def make_bounded_server(host, port, application):
    return make_server(host, port, application, server_class=BoundedWSGIServer,
                       handler_class=QuietRequestHandler)
