-- Studi kasus 3.2: Supabase/PostgreSQL audit trail dan immutable posted voucher.
-- Jalankan sebagai administrator database pada proyek Supabase.
-- Skema menggunakan auth.users dan auth.uid() dari Supabase Auth.

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE public.chart_of_accounts (
    account_code text PRIMARY KEY,
    account_name text NOT NULL,
    account_class text NOT NULL,
    is_cash_equivalent boolean NOT NULL DEFAULT false
);

CREATE TABLE public.voucher_headers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    voucher_no text NOT NULL UNIQUE,
    transaction_date date NOT NULL,
    description text NOT NULL,
    status text NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT', 'POSTED')),
    created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    posted_by uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
    posted_at timestamptz,
    hash_checksum text,
    reversal_of uuid UNIQUE
        REFERENCES public.voucher_headers(id) ON DELETE RESTRICT,
    CHECK (
        (status = 'DRAFT' AND posted_at IS NULL AND posted_by IS NULL
            AND hash_checksum IS NULL)
        OR
        (status = 'POSTED' AND posted_at IS NOT NULL AND posted_by IS NOT NULL
            AND hash_checksum IS NOT NULL)
    )
);

CREATE TABLE public.voucher_lines (
    line_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    header_id uuid NOT NULL
        REFERENCES public.voucher_headers(id) ON DELETE RESTRICT,
    line_no integer NOT NULL,
    account_code text NOT NULL
        REFERENCES public.chart_of_accounts(account_code) ON DELETE RESTRICT,
    memo text NOT NULL DEFAULT '',
    debit numeric(18,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit numeric(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    CHECK ((debit > 0 AND credit = 0) OR
           (credit > 0 AND debit = 0)),
    UNIQUE (header_id, line_no)
);

-- Tidak memakai FK ke voucher_headers supaya audit log draft yang dihapus
-- tetap dapat disimpan sebagai jejak historis.
CREATE TABLE public.audit_log (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_id uuid NOT NULL,
    actor_id uuid,
    event_type text NOT NULL,
    event_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    payload jsonb NOT NULL,
    hash_checksum text
);

-- Checksum dibuat dari metadata utama dan semua detail yang diurutkan.
CREATE OR REPLACE FUNCTION public.compute_voucher_checksum(p_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_payload jsonb;
BEGIN
    SELECT jsonb_build_object(
        'id', h.id,
        'voucher_no', h.voucher_no,
        'transaction_date', h.transaction_date,
        'description', h.description,
        'created_by', h.created_by,
        'created_at', h.created_at,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'line_no', l.line_no,
                'account_code', l.account_code,
                'memo', l.memo,
                'debit', l.debit,
                'credit', l.credit
            ) ORDER BY l.line_no)
            FROM public.voucher_lines l
            WHERE l.header_id = h.id
        ), '[]'::jsonb)
    ) INTO v_payload
    FROM public.voucher_headers h
    WHERE h.id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher % tidak ditemukan', p_id;
    END IF;

    RETURN encode(
        extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'),
        'hex'
    );
END;
$$;

-- Mengizinkan DRAFT diedit. Ketika berubah menjadi POSTED, database
-- memvalidasi keseimbangan, memastikan akun kas dikreditkan untuk voucher
-- kas keluar, menetapkan posted_at/posted_by/hash_checksum, dan kemudian
-- melarang semua perubahan berikutnya.
CREATE OR REPLACE FUNCTION public.guard_voucher_header()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
    v_debit numeric(18,2);
    v_credit numeric(18,2);
    v_cash_debit numeric(18,2);
    v_cash_credit numeric(18,2);
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'DRAFT' OR NEW.posted_at IS NOT NULL OR
           NEW.posted_by IS NOT NULL OR NEW.hash_checksum IS NOT NULL THEN
            RAISE EXCEPTION 'Voucher harus dibuat sebagai DRAFT; posting harus melalui validasi.';
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        IF OLD.status = 'POSTED' THEN
            RAISE EXCEPTION 'Voucher POSTED tidak boleh dihapus; buat reversing entry.';
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.status = 'POSTED' THEN
        RAISE EXCEPTION 'Voucher POSTED tidak boleh diubah; buat reversing entry.';
    END IF;

    IF NEW.created_by IS DISTINCT FROM OLD.created_by OR
       NEW.created_at IS DISTINCT FROM OLD.created_at THEN
        RAISE EXCEPTION 'created_by dan created_at bersifat tetap.';
    END IF;

    IF OLD.status = 'DRAFT' AND NEW.status = 'POSTED' THEN
        SELECT COUNT(*), COALESCE(SUM(debit), 0), COALESCE(SUM(credit), 0)
          INTO v_count, v_debit, v_credit
          FROM public.voucher_lines
         WHERE header_id = NEW.id;

        IF v_count < 2 THEN
            RAISE EXCEPTION 'Jurnal harus memiliki minimal dua baris.';
        END IF;

        IF v_debit <= 0 OR v_debit <> v_credit THEN
            RAISE EXCEPTION
                'Posting ditolak: total debit harus sama dengan kredit dan lebih dari nol.';
        END IF;

        SELECT
            COALESCE(SUM(CASE WHEN a.is_cash_equivalent THEN l.debit ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN a.is_cash_equivalent THEN l.credit ELSE 0 END), 0)
          INTO v_cash_debit, v_cash_credit
          FROM public.voucher_lines l
          JOIN public.chart_of_accounts a USING (account_code)
         WHERE l.header_id = NEW.id;

        IF NEW.reversal_of IS NULL THEN
            IF v_cash_credit <= 0 OR v_cash_debit <> 0 THEN
                RAISE EXCEPTION 'Voucher kas keluar harus mengkredit akun kas/bank.';
            END IF;
        ELSE
            IF NOT EXISTS (
                SELECT 1
                  FROM public.voucher_headers src
                 WHERE src.id = NEW.reversal_of AND src.status = 'POSTED'
            ) THEN
                RAISE EXCEPTION 'Voucher asal reversal harus berstatus POSTED.';
            END IF;

            IF v_cash_debit <= 0 OR v_cash_credit <> 0 THEN
                RAISE EXCEPTION 'Reversal kas keluar harus membalik debit/kredit akun kas.';
            END IF;

            -- Baris reversal wajib menukar debit/kredit dari sumber.
            IF EXISTS (
                (SELECT account_code, credit AS debit, debit AS credit
                   FROM public.voucher_lines
                  WHERE header_id = NEW.reversal_of
                 EXCEPT ALL
                 SELECT account_code, debit, credit
                   FROM public.voucher_lines
                  WHERE header_id = NEW.id)
                UNION ALL
                (SELECT account_code, debit, credit
                   FROM public.voucher_lines
                  WHERE header_id = NEW.id
                 EXCEPT ALL
                 SELECT account_code, credit AS debit, debit AS credit
                   FROM public.voucher_lines
                  WHERE header_id = NEW.reversal_of)
            ) THEN
                RAISE EXCEPTION 'Baris reversal harus membalik nominal tiap akun dari voucher asal.';
            END IF;
        END IF;

        NEW.posted_at := clock_timestamp();
        NEW.posted_by := COALESCE(NEW.posted_by, auth.uid(), NEW.created_by);
        NEW.hash_checksum := public.compute_voucher_checksum(NEW.id);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_guard_voucher_header
BEFORE INSERT OR UPDATE OR DELETE ON public.voucher_headers
FOR EACH ROW EXECUTE FUNCTION public.guard_voucher_header();

-- Mengunci header yang sama ketika detail dimasukkan/diubah/dihapus.
-- Ini menyerialisasi perubahan detail terhadap proses posting.
CREATE OR REPLACE FUNCTION public.guard_voucher_line()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_status text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT status INTO v_status
          FROM public.voucher_headers
         WHERE id = NEW.header_id
         FOR UPDATE;

        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Tidak boleh menambah baris ke voucher POSTED.';
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        SELECT status INTO v_status
          FROM public.voucher_headers
         WHERE id = OLD.header_id
         FOR UPDATE;

        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Tidak boleh menghapus baris voucher POSTED.';
        END IF;
        RETURN OLD;
    ELSE
        SELECT status INTO v_status
          FROM public.voucher_headers
         WHERE id = OLD.header_id
         FOR UPDATE;

        IF v_status = 'POSTED' THEN
            RAISE EXCEPTION 'Tidak boleh mengubah baris voucher POSTED.';
        END IF;

        IF NEW.header_id IS DISTINCT FROM OLD.header_id THEN
            SELECT status INTO v_status
              FROM public.voucher_headers
             WHERE id = NEW.header_id
             FOR UPDATE;

            IF v_status = 'POSTED' THEN
                RAISE EXCEPTION 'Tidak boleh memindahkan baris ke voucher POSTED.';
            END IF;
        END IF;
        RETURN NEW;
    END IF;
END;
$$;

CREATE TRIGGER trg_guard_voucher_line
BEFORE INSERT OR UPDATE OR DELETE ON public.voucher_lines
FOR EACH ROW EXECUTE FUNCTION public.guard_voucher_line();

-- Audit log bersifat append-only pada jalur aplikasi.
CREATE OR REPLACE FUNCTION public.deny_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit_log bersifat append-only; perubahan/penghapusan dilarang.';
END;
$$;

CREATE TRIGGER trg_audit_no_row_mutation
BEFORE UPDATE OR DELETE ON public.audit_log
FOR EACH ROW EXECUTE FUNCTION public.deny_audit_mutation();

CREATE TRIGGER trg_audit_no_truncate
BEFORE TRUNCATE ON public.audit_log
FOR EACH STATEMENT EXECUTE FUNCTION public.deny_audit_mutation();

REVOKE UPDATE, DELETE, TRUNCATE ON public.audit_log FROM PUBLIC;

-- Trigger berikut mencatat perubahan header dan detail (sebelum/sesudah).
-- Tetapkan owner SECURITY DEFINER secara hati-hati dan batasi execute grants.
CREATE OR REPLACE FUNCTION public.audit_header_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_actor uuid;
    v_event text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_actor := COALESCE(auth.uid(), NEW.created_by);
        INSERT INTO public.audit_log
            (voucher_id, actor_id, event_type, payload, hash_checksum)
        VALUES
            (NEW.id, v_actor, 'HEADER_CREATED',
             jsonb_build_object('new', to_jsonb(NEW)), NEW.hash_checksum);
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        v_actor := COALESCE(auth.uid(), NEW.posted_by, NEW.created_by);
        v_event := CASE
            WHEN OLD.status IS DISTINCT FROM NEW.status
                THEN 'VOUCHER_POSTED'
            ELSE 'HEADER_UPDATED'
        END;
        INSERT INTO public.audit_log
            (voucher_id, actor_id, event_type, payload, hash_checksum)
        VALUES
            (NEW.id, v_actor, v_event,
             jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW)),
             NEW.hash_checksum);
        RETURN NEW;
    ELSE
        v_actor := COALESCE(auth.uid(), OLD.created_by);
        INSERT INTO public.audit_log
            (voucher_id, actor_id, event_type, payload, hash_checksum)
        VALUES
            (OLD.id, v_actor, 'DRAFT_DELETED',
             jsonb_build_object('old', to_jsonb(OLD)), OLD.hash_checksum);
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER trg_audit_header_change
AFTER INSERT OR UPDATE OR DELETE ON public.voucher_headers
FOR EACH ROW EXECUTE FUNCTION public.audit_header_change();

CREATE OR REPLACE FUNCTION public.audit_line_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_id uuid;
    v_actor uuid;
    v_payload jsonb;
    v_event text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_id := OLD.header_id;
        v_payload := jsonb_build_object('old', to_jsonb(OLD));
        v_event := 'LINE_DELETED';
    ELSIF TG_OP = 'UPDATE' THEN
        v_id := NEW.header_id;
        v_payload := jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW));
        v_event := 'LINE_UPDATED';
    ELSE
        v_id := NEW.header_id;
        v_payload := jsonb_build_object('new', to_jsonb(NEW));
        v_event := 'LINE_CREATED';
    END IF;

    SELECT COALESCE(auth.uid(), h.created_by)
      INTO v_actor
      FROM public.voucher_headers h
     WHERE h.id = v_id;

    INSERT INTO public.audit_log
        (voucher_id, actor_id, event_type, payload, hash_checksum)
    VALUES
        (v_id, v_actor, v_event, v_payload,
         (SELECT h.hash_checksum FROM public.voucher_headers h WHERE h.id = v_id));

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_line_change
AFTER INSERT OR UPDATE OR DELETE ON public.voucher_lines
FOR EACH ROW EXECUTE FUNCTION public.audit_line_change();

-- Pemeriksaan checksum: nilai harus sama dengan hash yang dihitung ulang.
SELECT id, voucher_no,
       hash_checksum AS stored_hash,
       public.compute_voucher_checksum(id) AS recomputed_hash,
       hash_checksum = public.compute_voucher_checksum(id) AS checksum_valid
FROM public.voucher_headers
WHERE status = 'POSTED';

-- PENTING UNTUK PRODUKSI:
-- 1. Tambahkan kebijakan RLS dan grants minimum sesuai organisasi.
-- 2. Jangan memberi role aplikasi hak UPDATE/DELETE/TRUNCATE pada audit_log.
-- 3. Batasi siapa yang dapat mengubah master akun, membuat voucher, dan posting.
-- 4. Ekspor hash/audit log ke penyimpanan terpisah untuk perlindungan lebih kuat.
-- 5. Reversal harus dibuat sebagai voucher baru; jangan mengedit voucher POSTED.
