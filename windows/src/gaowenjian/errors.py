class AppError(Exception):
    def __init__(self, message: str, code: str = "error"):
        super().__init__(message)
        self.message = message
        self.code = code
