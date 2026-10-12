// Contoh akademik: Node.js + Express + pg.
 // requireAuth harus memverifikasi JWT/sesi Supabase dan menetapkan req.user.id.
 // Jangan menerima created_by sebagai nilai tepercaya dari browser.
 
 app.post('/api/vouchers', requireAuth, async (req, res) => {
   const { voucherNo, transactionDate, description, lines } = req.body;
   if (!voucherNo || !transactionDate || !description ||
       !Array.isArray(lines) || lines.length < 2) {
     return res.status(400).json({ message: 'Data voucher belum lengkap.' });
   }
 
   const client = await pool.connect();
   try {
     await client.query('BEGIN');
     const created = await client.query(
       `INSERT INTO public.voucher_headers
          (voucher_no, transaction_date, description, created_by)
        VALUES ($1, $2, $3, $4) RETURNING id`,
       [voucherNo, transactionDate, description, req.user.id]
     );
     const voucherId = created.rows[0].id;
 
     for (const [index, line] of lines.entries()) {
       await client.query(
         `INSERT INTO public.voucher_lines
            (header_id, line_no, account_code, memo, debit, credit)
          VALUES ($1, $2, $3, $4, $5, $6)`,
         [voucherId, index + 1, line.accountCode, line.memo || '',
          line.debit, line.credit]
       );
     }
 
     // Trigger database memeriksa balance, akun kas, posted_at dan checksum.
     await client.query(
       `UPDATE public.voucher_headers
          SET status = 'POSTED', posted_by = $2
        WHERE id = $1 AND status = 'DRAFT'`,
       [voucherId, req.user.id]
     );
     await client.query('COMMIT');
     return res.status(201).json({ id: voucherId, voucherNo, status: 'POSTED' });
   } catch (error) {
     await client.query('ROLLBACK');
     console.error('Voucher posting failed:', error); // log aman di server
     return res.status(400).json({
       message: 'Posting ditolak oleh validasi server/database.'
     });
   } finally {
     client.release();
   }
 });

 // Contoh inti pembentukan reversing entry (storno):
 // Jalankan di dalam transaksi backend setelah mengunci dan memverifikasi
 // voucher asal berstatus POSTED serta belum memiliki reversal.
 /*
 INSERT INTO public.voucher_headers
   (voucher_no, transaction_date, description, created_by, reversal_of)
 VALUES ($1, CURRENT_DATE, $2, $3, $4)
 RETURNING id;

 INSERT INTO public.voucher_lines
   (header_id, line_no, account_code, memo, debit, credit)
 SELECT $new_reversal_id, line_no, account_code,
        'Reversal dari voucher ' || $source_voucher_no, credit, debit
 FROM public.voucher_lines
 WHERE header_id = $source_voucher_id;

 UPDATE public.voucher_headers
 SET status = 'POSTED', posted_by = $authenticated_user_id
 WHERE id = $new_reversal_id AND status = 'DRAFT';
 */
