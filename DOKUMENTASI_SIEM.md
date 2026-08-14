# 🛡️ Dokumentasi & Panduan Deployment SIEM BD Gianyar

Dokumen ini berisi panduan teknis lengkap mengenai arsitektur sistem, cara melakukan *deploy* aplikasi web ke server, dan panduan penyisipan script PowerShell (Agent) ke seluruh komputer *client* di kantor Anda.

---

## 1. Alur Sistem (Flowchart Arsitektur)

Sistem ini beroperasi dengan model **Client-Server**. Komputer kantor (Client) secara aktif melaporkan kondisinya ke Server Pusat melalui API.

```mermaid
graph TD
    %% Entitas Utama
    Client["💻 Komputer Client (Windows)"]
    Agent["⚙️ usb_agent.ps1 (Background Service)"]
    Server["🖥️ Server SIEM (Linux / VPS)"]
    API["🌐 Flask API (app.py)"]
    DB[("🗄️ SQLite Database")]
    Dashboard["📊 Web Dashboard (React)"]
    Admin["👨‍💼 IT Admin"]

    %% Alur Client
    Client -->|Dijalankan saat Startup| Agent
    Agent -.->|1. Register & Heartbeat (Setiap 15 Detik)| API
    Agent -.->|2. Deteksi Login/Logout OS| API
    Agent -.->|3. Deteksi Aplikasi & Jendela Aktif| API
    
    %% Alur USB Policy
    API -.->|4. Sinkronisasi Kebijakan USB (Allow/Block)| Agent
    Agent -->|Terapkan Kebijakan (Disable/Enable Port)| Client
    Agent -.->|Kirim Log USB Dicolok/Dicabut| API

    %% Alur Server & Database
    API <-->|Tulis & Baca Data| DB
    Dashboard <-->|Request Data Analitik & Live Stream| API
    
    %% Alur Admin
    Admin -->|Akses UI (Merah-Putih)| Dashboard
    Admin -->|Ubah Kebijakan & Atur Profil| Dashboard
```

---

## 2. Cara Deploy Web SIEM ke Server / Hosting

Untuk skala perusahaan, aplikasi Flask (`app.py`) tidak boleh dijalankan menggunakan server bawaan (development server). Anda harus menggunakan **Gunicorn** sebagai *Application Server* dan **Nginx** sebagai *Web Server* (Reverse Proxy).

### Langkah-langkah Deployment di Linux (Ubuntu/Debian):

**1. Persiapan Direktori & Virtual Environment**
```bash
# Pindahkan semua file (app.py, index.html, usb_control.db) ke server produksi (misal: /var/www/siem)
cd /var/www/siem
sudo apt update && sudo apt install python3-venv python3-pip nginx
python3 -m venv venv
source venv/bin/activate
pip install flask flask-cors gunicorn
```

**2. Membuat Service Systemd untuk Gunicorn**
Agar aplikasi otomatis berjalan saat server di-restart, buat file service:
```bash
sudo nano /etc/systemd/system/siem.service
```
Isi file dengan:
```ini
[Unit]
Description=Gunicorn instance to serve SIEM BD Gianyar
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=/var/www/siem
Environment="PATH=/var/www/siem/venv/bin"
ExecStart=/var/www/siem/venv/bin/gunicorn --workers 3 --bind 127.0.0.1:5000 app:app

[Install]
WantedBy=multi-user.target
```
Jalankan service:
```bash
sudo systemctl start siem
sudo systemctl enable siem
```

---

### Langkah-langkah Deployment di Windows Server (IIS):
*(Direkomendasikan untuk Bank Daerah Gianyar di develop.bdgianyar.co.id/siem)*

Karena *Gunicorn* tidak kompatibel dengan Windows, kita menggunakan **Waitress** sebagai *Production Server* untuk Flask, dan **NSSM** untuk menjadikannya *Background Service*, lalu menggunakan **IIS** sebagai *Reverse Proxy*.

#### Tahap 1: Persiapan Python & Aplikasi
1. Download dan Install Python 3.10+ di Windows Server Anda (Pastikan centang **"Add Python to PATH"** saat instalasi).
2. Buat folder untuk aplikasi, misalnya di `C:\inetpub\wwwroot\siem` atau `C:\SIEM_BDGianyar`.
3. Pindahkan semua file (termasuk folder `templates` dan `static`) ke dalam folder tersebut.
4. Buka **Command Prompt (Run as Administrator)** dan jalankan:
   ```cmd
   cd C:\SIEM_BDGianyar
   python -m venv venv
   venv\Scripts\activate
   pip install flask waitress werkzeug
   ```

#### Tahap 2: Menjalankan Flask sebagai Windows Service
Agar web server tetap hidup walau server di-restart, gunakan NSSM (Non-Sucking Service Manager).
1. Download NSSM dari `nssm.cc`, ekstrak, dan jalankan Command Prompt (Admin) di folder `nssm\win64`.
2. Ketik perintah: `nssm install SIEM_Backend`
3. Akan muncul jendela GUI NSSM, isi dengan:
   * **Path:** `C:\SIEM_BDGianyar\venv\Scripts\waitress-serve.exe`
   * **Arguments:** `--port=5000 app:app`
   * **Directory:** `C:\SIEM_BDGianyar`
4. Klik **Install service**.
5. Mulai service dengan perintah CMD: `nssm start SIEM_Backend`.
*(Sekarang backend SIEM sudah hidup di `http://127.0.0.1:5000` di dalam server)*

#### Tahap 3: Konfigurasi IIS Reverse Proxy
Agar aplikasi bisa diakses melalui `develop.bdgianyar.co.id/siem` secara publik:
1. Buka IIS Manager.
2. Install modul tambahan IIS melalui *Web Platform Installer*:
   * **URL Rewrite**
   * **Application Request Routing (ARR)**
3. Buka **Application Request Routing Cache** di IIS (di level nama server/root), klik *Server Proxy Settings* di panel kanan, dan centang **Enable proxy**. Klik *Apply*.
4. Pergi ke *Sites* -> situs `develop.bdgianyar.co.id`.
5. Klik kanan pada situs tersebut -> **Add Application**.
   * **Alias:** `siem`
   * **Physical path:** Arahkan ke folder kosong (misal: `C:\inetpub\wwwroot\siem_empty`).
6. Klik *Application* `siem` yang baru dibuat, lalu buka **URL Rewrite**.
7. Klik **Add Rule(s)** -> **Reverse Proxy**.
   * Jika ditanya untuk enable proxy, klik OK.
   * **Inbound Rules:** Masukkan `127.0.0.1:5000`.
   * **Outbound Rules:** Jangan dicentang.
   * Klik OK.

#### Penting: Menyesuaikan Path di Frontend (`index.html`)
Karena Anda mendeploy ke *sub-directory* (`/siem`) dan bukan ke *root domain*, Anda perlu mengganti semua *fetch path* di `templates/index.html`:
* Ubah `/api/...` menjadi `./api/...` atau `/siem/api/...`
* Ubah `/static/new-logo-bdgianyar.png` menjadi `/siem/static/new-logo-bdgianyar.png`
* Ubah juga pada `usb_agent.ps1`: `$ServerApiUrl = "http://develop.bdgianyar.co.id/siem/api"`

Setelah ini, SIEM Web Dashboard sudah bisa diakses dari internet/intranet!

**3. Konfigurasi Nginx (Reverse Proxy)**
```bash
sudo nano /etc/nginx/sites-available/siem
```
Isi dengan:
```nginx
server {
    listen 80;
    server_name ip_server_anda atau domain.com;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```
Aktifkan Nginx:
```bash
sudo ln -s /etc/nginx/sites-available/siem /etc/nginx/sites-enabled
sudo nginx -t
sudo systemctl restart nginx
```
*(Catatan: Setelah server jalan, pastikan Anda mengubah variabel `$ServerApiUrl` di dalam script `usb_agent.ps1` menjadi `http://ip_server_anda/api` sebelum dipasang ke komputer klien).*

---

## 3. Cara Menyisipkan Script PowerShell (`usb_agent.ps1`) di Komputer Kantor

Karena script ini harus berjalan terus-menerus tanpa mengganggu *user* (berjalan di *background*) dan memiliki hak akses untuk mematikan port USB, metode terbaik adalah menggunakan **Task Scheduler (Penjadwal Tugas) Windows**.

### A. Jika Setup Secara Manual (Satu per Satu PC):
1. **Simpan Script:** *Copy* file `usb_agent.ps1` ke lokasi yang tersembunyi di C drive komputer klien, misalnya `C:\ProgramData\SiemAgent\usb_agent.ps1`.
2. Buka aplikasi **Task Scheduler** di Windows (Cari di Start Menu).
3. Di panel kanan, klik **Create Task...** (Jangan "Create Basic Task").
4. **Tab General:**
   - Name: `SIEM_USB_Agent`
   - Centang **Run whether user is logged on or not** (Agar tetap jalan meski belum ada yang login).
   - Centang **Run with highest privileges** (Sangat Penting! Ini wajib agar script bisa mendisable USB).
   - Configure for: Pilih Windows 10/11.
5. **Tab Triggers:**
   - Klik **New...**
   - Begin the task: Pilih **At startup**.
   - Klik OK.
6. **Tab Actions:**
   - Klik **New...**
   - Action: `Start a program`
   - Program/script: ketik `powershell.exe`
   - Add arguments (Kopi paste ini persis): 
     `-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\SiemAgent\usb_agent.ps1"`
   - Klik OK.
7. **Tab Settings:**
   - Hilangkan centang pada *Stop the task if it runs longer than: 3 days* agar tidak terhenti paksa.
8. Klik OK. Anda akan diminta memasukkan Password Administrator Windows. Selesai! Script akan otomatis menyala, tak terlihat, dan memantau PC secara *realtime* setiap kali PC dihidupkan.

### B. Jika Menggunakan Active Directory (GPO - Group Policy)
Jika kantor Anda menggunakan Domain Controller (Active Directory):
1. Taruh file `usb_agent.ps1` di folder *Shared Network* (Sysvol).
2. Buat GPO baru yang menerapkan **Startup Script** (Computer Configuration -> Policies -> Windows Settings -> Scripts -> Startup).
3. Arahkan ke script tersebut dengan parameter eksekusi Bypass. Ini akan otomatis menginstal dan menjalankan agent di **ratusan komputer sekaligus** tanpa harus menyentuh komputernya satu-satu.
