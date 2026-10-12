-- Studi kasus 1: General Ledger
-- Jalankan pada PostgreSQL.

CREATE TABLE chart_of_accounts (
    account_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_code VARCHAR(20) NOT NULL UNIQUE,
    account_name VARCHAR(100) NOT NULL,
    normal_balance VARCHAR(6) NOT NULL
        CHECK (normal_balance IN ('DEBIT', 'CREDIT')),
    report_classification VARCHAR(20) NOT NULL
        CHECK (report_classification IN
            ('ASET', 'LIABILITAS', 'EKUITAS', 'PENDAPATAN', 'BEBAN'))
);

CREATE TABLE journal_headers (
    journal_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_date DATE NOT NULL,
    reference_no VARCHAR(50) NOT NULL,
    description TEXT,
    posting_status VARCHAR(10) NOT NULL DEFAULT 'DRAFT'
        CHECK (posting_status IN ('DRAFT', 'POSTED', 'VOID'))
);

CREATE TABLE journal_lines (
    line_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    header_id BIGINT NOT NULL,
    account_id BIGINT NOT NULL,
    debit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    CONSTRAINT fk_lines_header FOREIGN KEY (header_id)
        REFERENCES journal_headers (journal_id) ON DELETE RESTRICT,
    CONSTRAINT fk_lines_account FOREIGN KEY (account_id)
        REFERENCES chart_of_accounts (account_id) ON DELETE RESTRICT,
    CONSTRAINT chk_line_not_both_zero
        CHECK (debit <> 0 OR credit <> 0),
    CONSTRAINT chk_line_one_side
        CHECK (NOT (debit > 0 AND credit > 0))
);

-- CHECK per baris tidak dapat membandingkan SUM debit dengan SUM kredit
-- seluruh jurnal. Pemeriksaan lintas-baris dilakukan ketika POSTED.

CREATE OR REPLACE FUNCTION assert_posted_journal_balanced(p_header_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_status VARCHAR(10);
    v_line_count BIGINT;
    v_total_debit NUMERIC(18,2);
    v_total_credit NUMERIC(18,2);
BEGIN
    SELECT posting_status INTO v_status
    FROM journal_headers
    WHERE journal_id = p_header_id;

    IF v_status = 'POSTED' THEN
        SELECT COUNT(*), COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
        INTO v_line_count, v_total_debit, v_total_credit
        FROM journal_lines
        WHERE header_id = p_header_id;

        IF v_line_count < 2 OR v_total_debit <= 0
           OR v_total_debit <> v_total_credit THEN
            RAISE EXCEPTION
                'Jurnal % tidak seimbang: debit %, kredit %, jumlah baris %',
                p_header_id, v_total_debit, v_total_credit, v_line_count;
        END IF;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION check_balance_from_lines()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        PERFORM assert_posted_journal_balanced(OLD.header_id);
    END IF;
    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        PERFORM assert_posted_journal_balanced(NEW.header_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_balance_from_lines
AFTER INSERT OR UPDATE OR DELETE ON journal_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION check_balance_from_lines();

CREATE OR REPLACE FUNCTION check_balance_when_posting()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM assert_posted_journal_balanced(NEW.journal_id);
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_balance_when_posting
AFTER INSERT OR UPDATE ON journal_headers
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION check_balance_when_posting();

-- Catatan produksi:
-- Batasi perubahan jurnal POSTED melalui hak akses database / trigger guard.
-- Koreksi transaksi POSTED sebaiknya menggunakan jurnal pembalik (reversal).
