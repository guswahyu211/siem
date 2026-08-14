import sqlite3
import re
import time
import os
from functools import wraps
from flask import Flask, request, jsonify, send_from_directory, session
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename
from flask_cors import CORS
from datetime import datetime, timedelta

app = Flask(__name__)
app.secret_key = 'bdgianyar_secure_secret_key_2026'
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Strict',
    SESSION_COOKIE_SECURE=False,
    UPLOAD_FOLDER='static/uploads'
)
CORS(app, supports_credentials=True)

# Ensure upload directory exists
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

DB_NAME = "usb_control.db"

def get_db():
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row
    return conn

@app.after_request
def add_security_headers(resp):
    resp.headers['X-Frame-Options'] = 'DENY'
    resp.headers['X-Content-Type-Options'] = 'nosniff'
    resp.headers['X-XSS-Protection'] = '1; mode=block'
    resp.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
    resp.headers['Content-Security-Policy'] = "default-src 'self' 'unsafe-inline' 'unsafe-eval' https://unpkg.com https://fonts.googleapis.com https://fonts.gstatic.com https://cdn.jsdelivr.net;"
    return resp

def init_db():
    conn = get_db()
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        role TEXT DEFAULT 'admin',
        full_name TEXT,
        nickname TEXT,
        job_title TEXT,
        profile_picture TEXT)''')
    
    # Safely add columns if table existed before
    try: c.execute('ALTER TABLE users ADD COLUMN full_name TEXT')
    except: pass
    try: c.execute('ALTER TABLE users ADD COLUMN nickname TEXT')
    except: pass
    try: c.execute('ALTER TABLE users ADD COLUMN job_title TEXT')
    except: pass
    try: c.execute('ALTER TABLE users ADD COLUMN profile_picture TEXT')
    except: pass

    c.execute('''CREATE TABLE IF NOT EXISTS devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        hostname TEXT UNIQUE NOT NULL,
        os_info TEXT, ip_address TEXT,
        agent_version TEXT DEFAULT '1.0',
        status TEXT DEFAULT 'offline',
        last_seen TIMESTAMP,
        registered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    c.execute('''CREATE TABLE IF NOT EXISTS usb_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_hostname TEXT, serial_number TEXT,
        device_name TEXT, action TEXT,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    c.execute('''CREATE TABLE IF NOT EXISTS login_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_hostname TEXT, username TEXT,
        action TEXT, ip_address TEXT,
        source TEXT DEFAULT 'agent',
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    c.execute('''CREATE TABLE IF NOT EXISTS user_activities (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_hostname TEXT, username TEXT,
        process_name TEXT, window_title TEXT,
        duration_seconds INTEGER DEFAULT 30,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    c.execute('''CREATE TABLE IF NOT EXISTS usb_policies (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        serial_number TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL, owner TEXT NOT NULL,
        action TEXT DEFAULT 'allow',
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    c.execute('''CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY, value TEXT)''')
    c.execute('''CREATE TABLE IF NOT EXISTS system_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        event_type TEXT, message TEXT,
        source TEXT, severity TEXT DEFAULT 'info',
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP)''')
    
    c.execute('INSERT OR IGNORE INTO settings (key,value) VALUES (?,?)', ('default_usb_policy', 'block'))
    
    c.execute('SELECT * FROM users WHERE username=?', ('admin',))
    admin_user = c.fetchone()
    if not admin_user:
        c.execute('INSERT INTO users (username,password_hash,full_name,nickname,job_title) VALUES (?,?,?,?,?)',
                 ('admin', generate_password_hash('admin123'), 'Administrator', 'Admin', 'Kasubag IT Developer'))
    else:
        if not admin_user['job_title']:
            c.execute('UPDATE users SET full_name=?, nickname=?, job_title=? WHERE username=?', 
                      ('Administrator', 'Admin', 'Kasubag IT Developer', 'admin'))
            
    conn.commit()
    conn.close()

def log_event(event_type, message, source='system', severity='info'):
    try:
        conn = get_db()
        conn.execute('INSERT INTO system_events (event_type,message,source,severity) VALUES (?,?,?,?)',
                    (event_type, message, source, severity))
        conn.commit()
        conn.close()
    except Exception:
        pass

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user_id' not in session:
            return jsonify({'status': 'error', 'message': 'Unauthorized'}), 401
        return f(*args, **kwargs)
    return decorated

login_attempts = {}

# ─── STATIC ─────────────────────────────────────────
@app.route('/')
def index():
    return send_from_directory('templates', 'index.html')

# ─── AUTH ────────────────────────────────────────────
@app.route('/api/login', methods=['POST'])
def login():
    ip = request.remote_addr
    now = time.time()
    if ip in login_attempts:
        login_attempts[ip] = [t for t in login_attempts[ip] if now - t < 300]
        if len(login_attempts[ip]) >= 5:
            return jsonify({"status": "error", "message": "Terlalu banyak percobaan. Coba lagi dalam 5 menit."}), 429
    data = request.json or {}
    username = data.get('username', '')
    password = data.get('password', '')
    if not username or not password:
        return jsonify({"status": "error", "message": "Username dan password diperlukan"}), 400
    conn = get_db()
    user = conn.execute('SELECT * FROM users WHERE username=?', (username,)).fetchone()
    conn.close()
    if user and check_password_hash(user['password_hash'], password):
        login_attempts.pop(ip, None)
        session['user_id'] = user['id']
        session['username'] = username
        session['role'] = user['role']
        log_event('web_login', f'{username} login ke dashboard', 'web', 'info')
        return jsonify({"status": "success", "user": dict(user)})
    login_attempts.setdefault(ip, []).append(now)
    time.sleep(1)
    return jsonify({"status": "error", "message": "Username atau password salah"}), 401

@app.route('/api/logout', methods=['POST'])
def logout():
    uname = session.get('username', 'unknown')
    session.clear()
    log_event('web_logout', f'{uname} logout dari dashboard', 'web', 'info')
    return jsonify({"status": "success"})

@app.route('/api/me', methods=['GET'])
def get_me():
    if 'user_id' in session:
        conn = get_db()
        user = conn.execute('SELECT * FROM users WHERE id=?', (session['user_id'],)).fetchone()
        conn.close()
        if user:
            return jsonify({"status": "success", "user": dict(user)})
    return jsonify({"status": "error"}), 401

# ─── USERS / PROFILE ─────────────────────────────────
@app.route('/api/users', methods=['GET'])
@login_required
def get_users():
    conn = get_db()
    users = conn.execute('SELECT id, username, role, full_name, nickname, job_title, profile_picture FROM users ORDER BY id ASC').fetchall()
    conn.close()
    return jsonify({"status": "success", "data": [dict(u) for u in users]})

@app.route('/api/users', methods=['POST'])
@login_required
def add_user():
    data = request.json or {}
    username = data.get('username', '').strip()
    password = data.get('password', '')
    full_name = data.get('full_name', '').strip()
    nickname = data.get('nickname', '').strip()
    job_title = data.get('job_title', '').strip()
    role = data.get('role', 'user')
    
    if not username or not password:
        return jsonify({"status": "error", "message": "Username dan password diperlukan"}), 400
        
    conn = get_db()
    try:
        conn.execute('INSERT INTO users (username, password_hash, role, full_name, nickname, job_title) VALUES (?,?,?,?,?,?)',
                    (username, generate_password_hash(password), role, full_name, nickname, job_title))
        conn.commit()
        log_event('user_added', f'User baru ditambahkan: {username}', 'web', 'info')
        return jsonify({"status": "success"})
    except sqlite3.IntegrityError:
        return jsonify({"status": "error", "message": "Username sudah digunakan"}), 409
    finally:
        conn.close()

@app.route('/api/users/<int:uid>', methods=['DELETE'])
@login_required
def delete_user(uid):
    if session.get('user_id') == uid:
        return jsonify({"status": "error", "message": "Tidak bisa menghapus akun Anda sendiri"}), 400
    conn = get_db()
    user = conn.execute('SELECT username FROM users WHERE id=?', (uid,)).fetchone()
    if user:
        if user['username'] == 'admin':
            return jsonify({"status": "error", "message": "Admin default tidak bisa dihapus"}), 400
        conn.execute('DELETE FROM users WHERE id=?', (uid,))
        conn.commit()
        log_event('user_deleted', f'User dihapus: {user["username"]}', 'web', 'warning')
        conn.close()
        return jsonify({"status": "success"})
    conn.close()
    return jsonify({"status": "error", "message": "User tidak ditemukan"}), 404

@app.route('/api/profile', methods=['PUT'])
@login_required
def update_profile():
    data = request.json or {}
    full_name = data.get('full_name', '').strip()
    nickname = data.get('nickname', '').strip()
    job_title = data.get('job_title', '').strip()
    
    conn = get_db()
    conn.execute('UPDATE users SET full_name=?, nickname=?, job_title=? WHERE id=?', 
                (full_name, nickname, job_title, session['user_id']))
    conn.commit()
    conn.close()
    return jsonify({"status": "success"})

@app.route('/api/profile/photo', methods=['POST'])
@login_required
def upload_photo():
    if 'photo' not in request.files:
        return jsonify({"status": "error", "message": "Tidak ada file"}), 400
    file = request.files['photo']
    if file.filename == '':
        return jsonify({"status": "error", "message": "Pilih file terlebih dahulu"}), 400
    
    if file:
        ext = file.filename.rsplit('.', 1)[1].lower() if '.' in file.filename else ''
        if ext not in ['jpg', 'jpeg', 'png', 'gif']:
            return jsonify({"status": "error", "message": "Format file tidak didukung"}), 400
            
        filename = secure_filename(f"user_{session['user_id']}_{int(time.time())}.{ext}")
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(filepath)
        
        conn = get_db()
        # Delete old photo if exists
        old = conn.execute('SELECT profile_picture FROM users WHERE id=?', (session['user_id'],)).fetchone()
        if old and old['profile_picture']:
            old_path = os.path.join(app.config['UPLOAD_FOLDER'], old['profile_picture'])
            if os.path.exists(old_path):
                try: os.remove(old_path)
                except: pass
                
        conn.execute('UPDATE users SET profile_picture=? WHERE id=?', (filename, session['user_id']))
        conn.commit()
        conn.close()
        
        return jsonify({"status": "success", "filename": filename})

@app.route('/api/profile/photo', methods=['DELETE'])
@login_required
def delete_photo():
    conn = get_db()
    old = conn.execute('SELECT profile_picture FROM users WHERE id=?', (session['user_id'],)).fetchone()
    if old and old['profile_picture']:
        old_path = os.path.join(app.config['UPLOAD_FOLDER'], old['profile_picture'])
        if os.path.exists(old_path):
            try: os.remove(old_path)
            except: pass
    conn.execute('UPDATE users SET profile_picture=NULL WHERE id=?', (session['user_id'],))
    conn.commit()
    conn.close()
    return jsonify({"status": "success"})

# ─── OVERVIEW ────────────────────────────────────────
@app.route('/api/overview', methods=['GET'])
@login_required
def overview():
    conn = get_db()
    today = datetime.now().strftime('%Y-%m-%d')
    cutoff = (datetime.now() - timedelta(minutes=2)).strftime('%Y-%m-%d %H:%M:%S')
    total_devices = conn.execute('SELECT COUNT(*) as c FROM devices').fetchone()['c']
    online = conn.execute('SELECT COUNT(*) as c FROM devices WHERE last_seen>=?', (cutoff,)).fetchone()['c']
    offline = total_devices - online
    logins_today = conn.execute("SELECT COUNT(*) as c FROM login_events WHERE date(timestamp)=?", (today,)).fetchone()['c']
    usb_today = conn.execute("SELECT COUNT(*) as c FROM usb_events WHERE date(timestamp)=?", (today,)).fetchone()['c']
    blocked_today = conn.execute("SELECT COUNT(*) as c FROM usb_events WHERE action='blocked' AND date(timestamp)=?", (today,)).fetchone()['c']
    conn.close()
    return jsonify({"status": "success", "data": {
        "total_devices": total_devices, "online": online, "offline": offline,
        "logins_today": logins_today, "usb_events_today": usb_today, "usb_blocked_today": blocked_today
    }})

@app.route('/api/events/recent', methods=['GET'])
@login_required
def recent_events():
    conn = get_db()
    events = conn.execute('SELECT * FROM system_events ORDER BY id DESC LIMIT 50').fetchall()
    conn.close()
    return jsonify({"status": "success", "data": [dict(e) for e in events]})

# ─── DEVICES ─────────────────────────────────────────
@app.route('/api/devices', methods=['GET'])
@login_required
def get_devices():
    conn = get_db()
    cutoff = (datetime.now() - timedelta(minutes=2)).strftime('%Y-%m-%d %H:%M:%S')
    devs = conn.execute('SELECT * FROM devices ORDER BY last_seen DESC').fetchall()
    conn.close()
    result = []
    for d in devs:
        dd = dict(d)
        dd['status'] = 'online' if d['last_seen'] and d['last_seen'] >= cutoff else 'offline'
        result.append(dd)
    return jsonify({"status": "success", "data": result})

# ─── USB EVENTS ──────────────────────────────────────
@app.route('/api/usb-events', methods=['GET'])
@login_required
def get_usb_events():
    date_filter = request.args.get('date')
    conn = get_db()
    if date_filter:
        events = conn.execute('SELECT * FROM usb_events WHERE date(timestamp)=? ORDER BY id DESC LIMIT 500', (date_filter,)).fetchall()
    else:
        events = conn.execute('SELECT * FROM usb_events ORDER BY id DESC LIMIT 200').fetchall()
    conn.close()
    return jsonify({"status": "success", "data": [dict(e) for e in events]})

# ─── LOGIN EVENTS ────────────────────────────────────
@app.route('/api/login-events', methods=['GET'])
@login_required
def get_login_events():
    date_filter = request.args.get('date')
    conn = get_db()
    if date_filter:
        events = conn.execute('SELECT * FROM login_events WHERE date(timestamp)=? ORDER BY id DESC LIMIT 500', (date_filter,)).fetchall()
    else:
        events = conn.execute('SELECT * FROM login_events ORDER BY id DESC LIMIT 200').fetchall()
    conn.close()
    return jsonify({"status": "success", "data": [dict(e) for e in events]})

# ─── USER ACTIVITIES ─────────────────────────────────
@app.route('/api/user-activities', methods=['GET'])
@login_required
def get_user_activities():
    date_filter = request.args.get('date', datetime.now().strftime('%Y-%m-%d'))
    conn = get_db()
    agg = conn.execute('''SELECT process_name, SUM(duration_seconds) as total_seconds, COUNT(*) as count
        FROM user_activities WHERE date(timestamp)=? GROUP BY process_name ORDER BY total_seconds DESC LIMIT 30''', (date_filter,)).fetchall()
    
    if request.args.get('date'):
        logs = conn.execute('SELECT * FROM user_activities WHERE date(timestamp)=? ORDER BY id DESC LIMIT 500', (date_filter,)).fetchall()
    else:
        logs = conn.execute('SELECT * FROM user_activities ORDER BY id DESC LIMIT 100').fetchall()
        
    conn.close()
    return jsonify({"status": "success", "aggregated": [dict(a) for a in agg], "logs": [dict(l) for l in logs]})

# ─── USB POLICIES ────────────────────────────────────
@app.route('/api/usb-policies', methods=['GET'])
@login_required
def get_policies():
    conn = get_db()
    policies = conn.execute('SELECT * FROM usb_policies ORDER BY id DESC').fetchall()
    conn.close()
    return jsonify({"status": "success", "data": [dict(p) for p in policies]})

@app.route('/api/usb-policies', methods=['POST'])
@login_required
def add_policy():
    data = request.json or {}
    sn = re.sub(r'[^a-zA-Z0-9]', '', data.get('serial_number', '')).upper()
    name = data.get('name', '').strip()
    owner = data.get('owner', '').strip()
    action = data.get('action', 'allow')
    if not sn or not name or not owner:
        return jsonify({"status": "error", "message": "Semua field harus diisi"}), 400
    if action not in ('allow', 'block'):
        action = 'allow'
    conn = get_db()
    try:
        conn.execute('INSERT INTO usb_policies (serial_number,name,owner,action) VALUES (?,?,?,?)',
                    (sn, name, owner, action))
        conn.commit()
        log_event('policy_add', f'Aturan USB ditambahkan: {sn} ({action})', 'web', 'info')
        policy = conn.execute('SELECT * FROM usb_policies WHERE serial_number=?', (sn,)).fetchone()
        conn.close()
        return jsonify({"status": "success", "data": dict(policy)})
    except sqlite3.IntegrityError:
        conn.close()
        return jsonify({"status": "error", "message": "Serial number sudah terdaftar"}), 409

@app.route('/api/usb-policies/<int:pid>', methods=['DELETE'])
@login_required
def delete_policy(pid):
    conn = get_db()
    p = conn.execute('SELECT serial_number FROM usb_policies WHERE id=?', (pid,)).fetchone()
    if p:
        conn.execute('DELETE FROM usb_policies WHERE id=?', (pid,))
        conn.commit()
        log_event('policy_delete', f'Aturan USB dihapus: {p["serial_number"]}', 'web', 'warning')
        conn.close()
        return jsonify({"status": "success"})
    conn.close()
    return jsonify({"status": "error", "message": "Tidak ditemukan"}), 404

@app.route('/api/usb-policies/<int:pid>/toggle', methods=['PUT'])
@login_required
def toggle_policy(pid):
    conn = get_db()
    p = conn.execute('SELECT * FROM usb_policies WHERE id=?', (pid,)).fetchone()
    if p:
        new_action = 'block' if p['action'] == 'allow' else 'allow'
        conn.execute('UPDATE usb_policies SET action=? WHERE id=?', (new_action, pid))
        conn.commit()
        log_event('policy_toggle', f'Aturan USB {p["serial_number"]} diubah ke {new_action}', 'web', 'info')
        updated = conn.execute('SELECT * FROM usb_policies WHERE id=?', (pid,)).fetchone()
        conn.close()
        return jsonify({"status": "success", "data": dict(updated)})
    conn.close()
    return jsonify({"status": "error"}), 404

@app.route('/api/settings/default-policy', methods=['GET'])
@login_required
def get_default_policy():
    conn = get_db()
    r = conn.execute("SELECT value FROM settings WHERE key='default_usb_policy'").fetchone()
    conn.close()
    return jsonify({"status": "success", "policy": r['value'] if r else 'block'})

@app.route('/api/settings/default-policy', methods=['POST'])
@login_required
def set_default_policy():
    data = request.json or {}
    policy = data.get('policy', 'block')
    if policy not in ('allow', 'block'):
        policy = 'block'
    conn = get_db()
    conn.execute("INSERT OR REPLACE INTO settings (key,value) VALUES ('default_usb_policy',?)", (policy,))
    conn.commit()
    conn.close()
    label = 'DIBLOKIR' if policy == 'block' else 'DIIZINKAN'
    log_event('policy_default', f'Kebijakan default USB diubah ke {label}', 'web', 'warning')
    return jsonify({"status": "success", "policy": policy})

@app.route('/api/settings/clear-logs', methods=['POST'])
@login_required
def clear_all_logs():
    data = request.json or {}
    password = data.get('password', '')
    
    if not password:
        return jsonify({"status": "error", "message": "Password diperlukan"}), 400
        
    conn = get_db()
    user = conn.execute('SELECT password_hash FROM users WHERE id=?', (session['user_id'],)).fetchone()
    
    if not user or not check_password_hash(user['password_hash'], password):
        conn.close()
        return jsonify({"status": "error", "message": "Password salah"}), 401
        
    # Hapus semua log
    conn.execute('DELETE FROM usb_events')
    conn.execute('DELETE FROM login_events')
    conn.execute('DELETE FROM user_activities')
    conn.execute('DELETE FROM system_events')
    conn.execute('DELETE FROM devices')
    # Reset auto increment (opsional)
    conn.execute('DELETE FROM sqlite_sequence WHERE name IN ("usb_events", "login_events", "user_activities", "system_events", "devices")')
    conn.commit()
    conn.close()
    
    # Log aktivitas penghapusan ini
    log_event('logs_cleared', f'Semua log telah dihapus oleh {session.get("username")}', 'web', 'critical')
    return jsonify({"status": "success"})

# ─── AGENT ENDPOINTS (no auth) ──────────────────────
@app.route('/api/agent/register', methods=['POST'])
def agent_register():
    data = request.json or {}
    hostname = data.get('hostname', '').strip()
    if not hostname:
        return jsonify({"status": "error"}), 400
    conn = get_db()
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    existing = conn.execute('SELECT id FROM devices WHERE hostname=?', (hostname,)).fetchone()
    if existing:
        conn.execute('UPDATE devices SET os_info=?,ip_address=?,agent_version=?,last_seen=?,status=? WHERE hostname=?',
                    (data.get('os',''), data.get('ip',''), data.get('agent_version','1.0'), now, 'online', hostname))
    else:
        conn.execute('INSERT INTO devices (hostname,os_info,ip_address,agent_version,last_seen,status) VALUES (?,?,?,?,?,?)',
                    (hostname, data.get('os',''), data.get('ip',''), data.get('agent_version','1.0'), now, 'online'))
        log_event('device_register', f'Perangkat baru terdaftar: {hostname}', 'agent', 'info')
    conn.commit()
    conn.close()
    return jsonify({"status": "success"})

@app.route('/api/agent/heartbeat', methods=['POST'])
def agent_heartbeat():
    data = request.json or {}
    hostname = data.get('hostname', '').strip()
    if not hostname:
        return jsonify({"status": "error"}), 400
    conn = get_db()
    now = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    conn.execute('UPDATE devices SET last_seen=?,status=?,ip_address=? WHERE hostname=?',
                (now, 'online', data.get('ip', ''), hostname))
    conn.commit()
    conn.close()
    return jsonify({"status": "success"})

@app.route('/api/agent/usb-event', methods=['POST'])
def agent_usb_event():
    data = request.json or {}
    hostname = data.get('hostname', '')
    sn = data.get('serial_number', '')
    name = data.get('device_name', '')
    action = data.get('action', 'connected')
    conn = get_db()
    conn.execute('INSERT INTO usb_events (device_hostname,serial_number,device_name,action) VALUES (?,?,?,?)',
                (hostname, sn, name, action))
    conn.commit()
    sev = 'warning' if action == 'blocked' else 'info'
    log_event('usb_event', f'USB {sn} {action} pada {hostname}', 'agent', sev)
    conn.close()
    return jsonify({"status": "success"})

@app.route('/api/agent/login-event', methods=['POST'])
def agent_login_event():
    data = request.json or {}
    conn = get_db()
    conn.execute('INSERT INTO login_events (device_hostname,username,action,ip_address,source) VALUES (?,?,?,?,?)',
                (data.get('hostname',''), data.get('username',''), data.get('action','login'),
                 data.get('ip',''), 'agent'))
    conn.commit()
    log_event('login_event', f'{data.get("username","")} {data.get("action","login")} pada {data.get("hostname","")}', 'agent', 'info')
    conn.close()
    return jsonify({"status": "success"})

@app.route('/api/agent/user-activity', methods=['POST'])
def agent_user_activity():
    data = request.json or {}
    conn = get_db()
    conn.execute('INSERT INTO user_activities (device_hostname,username,process_name,window_title,duration_seconds) VALUES (?,?,?,?,?)',
                (data.get('hostname',''), data.get('username',''), data.get('process_name',''),
                 data.get('window_title',''), data.get('duration', 30)))
    conn.commit()
    conn.close()
    return jsonify({"status": "success"})

@app.route('/api/allowed_usbs', methods=['GET'])
def api_allowed_usbs():
    conn = get_db()
    dp = conn.execute("SELECT value FROM settings WHERE key='default_usb_policy'").fetchone()
    default_policy = dp['value'] if dp else 'block'
    policies = conn.execute('SELECT serial_number, action FROM usb_policies').fetchall()
    allowed = [re.sub(r'[^a-zA-Z0-9]','',p['serial_number']).upper() for p in policies if p['action']=='allow']
    blocked = [re.sub(r'[^a-zA-Z0-9]','',p['serial_number']).upper() for p in policies if p['action']=='block']
    conn.close()
    return jsonify({
        "status": "success",
        "default_policy": default_policy,
        "allowed_serials": allowed,
        "blocked_serials": blocked
    })

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=5000, debug=True)
