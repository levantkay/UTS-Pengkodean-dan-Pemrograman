# UTS Pengkodean dan Pemrograman

Kumpulan kode sumber untuk tiga studi kasus UTS:
1. **General Ledger** — skema relasional, constraint, dan validasi keseimbangan jurnal ketika posting.
2. **Persediaan perpetual** — trigger mutasi stok otomatis, anti-negative inventory, dan contoh pencegahan race condition.
3. **Voucher kas keluar** — purwarupa web dinamis, schema PostgreSQL/Supabase, checksum SHA-256, audit log, endpoint Express, dan reversing entry.

## Struktur repository

```text
.gitignore
01-general-ledger/
  general_ledger.sql
02-inventory/
  inventory_schema.sql
  inventory_trigger.sql
  concurrency_example.sql
03-voucher/
  voucher_prototype.html
  voucher_schema_audit.sql
  seed_accounts.example.sql
  backend.example.js
```

## Cara menggunakan

### 1. General Ledger
Jalankan `01-general-ledger/general_ledger.sql` pada PostgreSQL. Tabel yang dibuat adalah `chart_of_accounts`, `journal_headers`, dan `journal_lines`. Constraint memvalidasi nominal pada tiap baris, sedangkan deferred constraint trigger memeriksa total debit dan kredit ketika jurnal berstatus `POSTED`.

### 2. Inventory perpetual
Jalankan berurutan:
1. `02-inventory/inventory_schema.sql`
2. `02-inventory/inventory_trigger.sql`

`inventory_trigger.sql` membuat `trg_update_stock_and_journal()`, yang memutakhirkan `stock_qty` secara otomatis dan menolak penjualan atau penyesuaian yang menghasilkan stok negatif. `concurrency_example.sql` menunjukkan penggunaan `SELECT ... FOR UPDATE` dalam satu blok transaksi. Ubah kode item contoh `BRG001` menjadi item yang sudah ada di database.

### 3. Voucher kas keluar
1. Jalankan `03-voucher/voucher_schema_audit.sql` pada proyek Supabase/PostgreSQL yang sudah menggunakan Supabase Auth.
2. Opsional untuk data uji: jalankan `03-voucher/seed_accounts.example.sql`. Tinjau dan sesuaikan master akun sebelum dipakai.
3. Sajikan `03-voucher/voucher_prototype.html` lewat web server. Form mengirim payload ke endpoint `POST /api/vouchers`.
4. Sesuaikan `03-voucher/backend.example.js` dengan konfigurasi Express, koneksi `pg`, dan middleware autentikasi yang benar-benar memverifikasi JWT/sesi.
5. Tambahkan kebijakan RLS serta grants berdasarkan kebutuhan organisasi sebelum demo menggunakan akun nyata.

Frontend hanya validasi awal. PostgreSQL tetap memvalidasi keseimbangan dan status, menolak perubahan voucher `POSTED`, membuat checksum, dan mencatat event audit. Koreksi transaksi posted dilakukan dengan voucher reversal baru.

## Catatan keamanan

- Jangan pernah commit `.env`, password, access token, Supabase service-role key, atau kredensial lain. `.gitignore` mengecualikan file env dan file kunci yang umum.
- Kode adalah purwarupa akademik dan perlu dites pada database uji sebelum dipakai.
- Contoh voucher bergantung pada `auth.users` dan `auth.uid()` dari Supabase. Untuk PostgreSQL biasa, sesuaikan referensi pengguna dan autentikasi.
- SHA-256 hanya menunjukkan konsistensi konten ketika checksum dihitung ulang; hash pada database yang sama bukan pengganti kontrol akses. Untuk kebutuhan audit yang lebih kuat, salin log/checksum secara berkala ke penyimpanan terpisah yang tidak dapat ditulis oleh aplikasi.
- Akun kas/setara kas harus diklasifikasikan sesuai substansi transaksi dan kebijakan akuntansi, bukan hanya label akun.
