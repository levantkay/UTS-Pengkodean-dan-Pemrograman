-- Studi kasus 2.1: update stok otomatis dan pencegahan stok negatif.
-- PURCHASE dan SALE memakai qty positif.
-- ADJUSTMENT: qty positif menambah stok, negatif mengurangi stok.

CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_stock INTEGER;
    v_new_stock INTEGER;
    v_delta INTEGER;
BEGIN
    -- Baris item dikunci agar concurrent sale tidak memakai stok lama bersamaan.
    SELECT stock_qty
      INTO v_current_stock
      FROM inventory_items
     WHERE item_id = NEW.item_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Item dengan kode % tidak ditemukan.', NEW.item_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF NEW.qty = 0 THEN
        RAISE EXCEPTION 'Kuantitas transaksi tidak boleh nol.'
            USING ERRCODE = 'check_violation';
    END IF;

    CASE NEW.trx_type
        WHEN 'PURCHASE' THEN
            IF NEW.qty < 0 THEN
                RAISE EXCEPTION 'Kuantitas PURCHASE harus positif.';
            END IF;
            v_delta := NEW.qty;
        WHEN 'SALE' THEN
            IF NEW.qty < 0 THEN
                RAISE EXCEPTION 'Kuantitas SALE harus positif.';
            END IF;
            v_delta := -NEW.qty;
        WHEN 'ADJUSTMENT' THEN
            v_delta := NEW.qty;
        ELSE
            RAISE EXCEPTION 'Jenis transaksi % tidak valid.', NEW.trx_type
                USING ERRCODE = 'check_violation';
    END CASE;

    v_new_stock := v_current_stock + v_delta;

    IF NEW.trx_type = 'SALE' AND v_new_stock < 0 THEN
        RAISE EXCEPTION
            'Stok tidak cukup untuk item %. Stok tersedia: %, jumlah diminta: %.',
            NEW.item_id, v_current_stock, NEW.qty
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.trx_type = 'ADJUSTMENT' AND v_new_stock < 0 THEN
        RAISE EXCEPTION
            'Penyesuaian akan membuat stok item % menjadi negatif.', NEW.item_id
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE inventory_items
       SET stock_qty = v_new_stock
     WHERE item_id = NEW.item_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER inventory_transactions_after_insert
AFTER INSERT ON inventory_transactions
FOR EACH ROW
EXECUTE FUNCTION trg_update_stock_and_journal();
