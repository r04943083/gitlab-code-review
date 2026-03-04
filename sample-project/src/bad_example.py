"""
Sample code with intentional security vulnerabilities for testing the code review bot.
DO NOT use this code in production!
"""

import os
import pickle
import random
import sqlite3
import subprocess


# 1. Hardcoded credentials
DB_HOST = "192.168.1.100"
DB_USER = "admin"
DB_PASSWORD = "Super$ecret123!"
API_KEY = "sk-1234567890abcdef"


def get_db_connection():
    """Connect to database with hardcoded credentials."""
    conn = sqlite3.connect("app.db")
    return conn


# 2. SQL Injection vulnerability
def get_user(username):
    """Fetch user by username - vulnerable to SQL injection."""
    conn = get_db_connection()
    cursor = conn.cursor()
    query = f"SELECT * FROM users WHERE username = '{username}'"
    cursor.execute(query)
    result = cursor.fetchone()
    conn.close()
    return result


# 3. Command injection vulnerability
def process_file(filename):
    """Process a file - vulnerable to command injection."""
    os.system(f"cat {filename} | wc -l")
    result = subprocess.call(f"grep -c 'error' {filename}", shell=True)
    return result


# 4. Pickle deserialization of untrusted data
def load_user_data(data_bytes):
    """Load user data from bytes - vulnerable to pickle deserialization attack."""
    return pickle.loads(data_bytes)


# 5. Insecure random for security-sensitive operation
def generate_token():
    """Generate auth token - using insecure random."""
    chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    token = "".join(random.choice(chars) for _ in range(32))
    return token


# 6. Missing input validation
def transfer_money(from_account, to_account, amount):
    """Transfer money between accounts - no validation."""
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute(
        f"UPDATE accounts SET balance = balance - {amount} WHERE id = '{from_account}'"
    )
    cursor.execute(
        f"UPDATE accounts SET balance = balance + {amount} WHERE id = '{to_account}'"
    )
    conn.commit()
    conn.close()
    return True


# 7. Broad exception catching
def risky_operation():
    """Perform risky operation with overly broad exception handling."""
    try:
        data = open("/etc/passwd").read()
        result = eval(data)
        return result
    except:
        pass


# 8. Path traversal vulnerability
def read_config(config_name):
    """Read config file - vulnerable to path traversal."""
    path = f"/app/configs/{config_name}"
    with open(path, "r") as f:
        return f.read()


# 9. Logging sensitive data
def authenticate(username, password):
    """Authenticate user - logs sensitive data."""
    print(f"Login attempt: user={username}, password={password}")
    if username == DB_USER and password == DB_PASSWORD:
        return generate_token()
    return None
