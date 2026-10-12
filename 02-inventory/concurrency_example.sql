-- Studi kasus 2.2: SELECT ... FOR UPDATE + pemeriksaan stok
-- Ganti BRG001 dengan item_id yang benar. Jalankan sebagai satu blok.
-- Trigger trg_update_stock_and_journal() mengunci baris yang sama dan memeriksa
-- stok kembali saat INSERT. Jika stok tinggal 1 dan dua kasir menjual 1 unit,
-- satu transaksi berhasil dan transaksi lainnya ditolak setelah menunggu lock.

DO $$
DECLARE
    v_item_id VARCHAR(10) := 'BRG001';
    v_qty INTEGER := 1;
    v_available INTEGER;
BEGIN
    SELECT stock_qty
      INTO v_available
      FROM inventory_items
     WHERE item_id = v_item_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item % tidak ditemukan.', v_item_id;
    END IF;

    IF v_available < v_qty THEN
        RAISE EXCEPTION 'Stok tidak cukup. Tersedia: %, diminta: %.',
            v_available, v_qty
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO inventory_transactions (item_id, trx_type, qty)
    VALUES (v_item_id, 'SALE', v_qty);
    -- Trigger mengurangi stok dan melakukan validasi ulang.
END;
$$;

-- Alternatif:
-- SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
-- Jalankan pemeriksaan stok dan INSERT dalam transaksi yang sama.
-- Aplikasi harus menangani SQLSTATE 40001 (serialization_failure) dengan retry.
