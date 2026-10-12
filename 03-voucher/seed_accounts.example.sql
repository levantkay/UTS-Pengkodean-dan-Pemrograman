-- Contoh master akun agar kode akun frontend sesuai dengan database.
-- Sesuaikan dengan chart of accounts resmi entitas sebelum digunakan.
INSERT INTO public.chart_of_accounts
    (account_code, account_name, account_class, is_cash_equivalent)
VALUES
    ('1110', 'Kas Kecil', 'ASET', true),
    ('1120', 'Bank / Giro', 'ASET', true),
    ('2100', 'Utang Usaha', 'LIABILITAS', false),
    ('5100', 'Beban Operasional', 'BEBAN', false),
    ('1510', 'Perlengkapan', 'ASET', false),
    ('1600', 'Aset Tetap', 'ASET', false),
    ('6100', 'Beban Bunga', 'BEBAN', false)
ON CONFLICT (account_code) DO NOTHING;
