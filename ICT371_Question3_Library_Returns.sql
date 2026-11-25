
/*
Student Name: YOUR FULL NAME
Student Number: YOUR STUDENT NUMBER
Course Code: ICT371
Assignment: Question 3 - Library Returns and Overdue Fines
*/

/* =====================================================
   STEP 1: REMOVE PREVIOUS QUESTION 3 OBJECTS
   ===================================================== */

DROP VIEW IF EXISTS v_overdue_loans CASCADE;

DROP TABLE IF EXISTS
    loan_audit,
    overdue_summary,
    loans,
    books
CASCADE;

DROP PROCEDURE IF EXISTS
    pr_return_loan(INTEGER, DATE);

DROP PROCEDURE IF EXISTS
    pr_refresh_overdue(DATE);

DROP FUNCTION IF EXISTS
    fn_loan_fine(INTEGER, DATE);

DROP FUNCTION IF EXISTS
    fn_loan_audit();


/* =====================================================
   STEP 2: CREATE THE BOOKS TABLE
   ===================================================== */

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);


/* =====================================================
   STEP 3: CREATE THE LOANS TABLE
   ===================================================== */

CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,
    book_id INTEGER NOT NULL
        REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE,
    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0
        CHECK (fine_amount >= 0),

    CONSTRAINT chk_loan_dates
        CHECK (due_on >= borrowed_on),

    CONSTRAINT chk_return_date
        CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);


/* =====================================================
   STEP 4: CREATE THE LOAN AUDIT TABLE
   ===================================================== */

CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,
    loan_id INTEGER NOT NULL
        REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);


/* =====================================================
   STEP 5: CREATE THE OVERDUE SUMMARY TABLE
   ===================================================== */

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine NUMERIC(12,2) NOT NULL DEFAULT 0
);


/* =====================================================
   STEP 6: INSERT THREE BOOKS
   ===================================================== */

INSERT INTO books (title)
VALUES
    ('Introduction to Database Systems'),
    ('Computer Networking Basics'),
    ('Programming with Python');


/* =====================================================
   STEP 7: CREATE THE LOAN FINE FUNCTION
   K2 PER OVERDUE DAY
   ===================================================== */

CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of DATE
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_date DATE;
    v_days_overdue INTEGER;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Calculation date cannot be NULL';
    END IF;

    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Loan ID % does not exist',
            p_loan_id;
    END IF;

    -- Use the earlier of the calculation date
    -- and the return date, if the loan was returned.

    v_effective_date := LEAST(
        p_as_of,
        COALESCE(v_returned_on, p_as_of)
    );

    v_days_overdue := GREATEST(
        0,
        v_effective_date - v_due_on
    );

    RETURN v_days_overdue * 2.00;
END;
$$;


/* =====================================================
   STEP 8: INSERT SIX LOAN RECORDS
   Includes open overdue, on-time and returned loans.
   ===================================================== */

INSERT INTO loans (
    book_id,
    borrower_name,
    borrowed_on,
    due_on,
    returned_on,
    fine_amount
)
VALUES
    -- Open overdue loan: overdue by 5 days
    (1, 'John Banda',
     CURRENT_DATE - 15,
     CURRENT_DATE - 5,
     NULL, 0),

    -- Open loan due today: no fine
    (2, 'Mary Phiri',
     CURRENT_DATE - 10,
     CURRENT_DATE,
     NULL, 0),

    -- Returned loan: returned 3 days after due date
    (3, 'Peter Zulu',
     CURRENT_DATE - 20,
     CURRENT_DATE - 10,
     CURRENT_DATE - 7, 0),

    -- Open overdue loan: overdue by 2 days
    (1, 'Grace Tembo',
     CURRENT_DATE - 12,
     CURRENT_DATE - 2,
     NULL, 0),

    -- Open loan with a future due date
    (2, 'David Chanda',
     CURRENT_DATE - 3,
     CURRENT_DATE + 5,
     NULL, 0),

    -- Returned on the due date: no fine
    (3, 'Ruth Mwila',
     CURRENT_DATE - 8,
     CURRENT_DATE - 3,
     CURRENT_DATE - 3, 0);


/* =====================================================
   STEP 9: CREATE THE LOAN AUDIT TRIGGER FUNCTION
   ===================================================== */

CREATE OR REPLACE FUNCTION fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN

        INSERT INTO loan_audit (
            loan_id,
            old_returned_on,
            new_returned_on,
            changed_at
        )
        VALUES (
            NEW.loan_id,
            OLD.returned_on,
            NEW.returned_on,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;
END;
$$;


/* =====================================================
   STEP 10: CREATE THE AFTER UPDATE AUDIT TRIGGER
   ===================================================== */

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION fn_loan_audit();


/* =====================================================
   STEP 11: CALCULATE INITIAL FINES FOR ALL SIX LOANS
   ===================================================== */

UPDATE loans
SET fine_amount = fn_loan_fine(loan_id, CURRENT_DATE);


/* =====================================================
   STEP 12: CREATE THE RETURN LOAN PROCEDURE
   ===================================================== */

CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_existing_return DATE;
    v_final_fine NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date cannot be NULL';
    END IF;

    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_existing_return
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Loan ID % does not exist',
            p_loan_id;
    END IF;

    IF v_existing_return IS NOT NULL THEN
        RAISE EXCEPTION
            'Loan ID % has already been returned',
            p_loan_id;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION
            'Return date cannot be before the borrowed date';
    END IF;

    -- Calculate the final fine using the proposed
    -- return date before updating the loan.

    v_final_fine := GREATEST(
        0,
        p_returned_on -
        (SELECT due_on FROM loans WHERE loan_id = p_loan_id)
    ) * 2.00;

    UPDATE loans
    SET
        returned_on = p_returned_on,
        fine_amount = v_final_fine
    WHERE loan_id = p_loan_id;

END;
$$;


/* =====================================================
   STEP 13: CREATE THE OVERDUE LOANS VIEW
   ===================================================== */

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_amount
FROM loans l
JOIN books b
    ON l.book_id = b.book_id
WHERE l.returned_on IS NULL
AND l.due_on < CURRENT_DATE;


/* =====================================================
   STEP 14: CREATE THE PARTIAL INDEX
   Supports searches for unreturned loans by book.
   ===================================================== */

CREATE INDEX idx_loans_unreturned_book
ON loans (book_id)
WHERE returned_on IS NULL;


/* =====================================================
   STEP 15: CREATE THE OVERDUE SUMMARY PROCEDURE
   ===================================================== */

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'Snapshot date cannot be NULL';
    END IF;

    INSERT INTO overdue_summary (
        snapshot_date,
        overdue_count,
        total_fine
    )
    SELECT
        p_as_of,
        COUNT(*)::INTEGER,
        COALESCE(
            SUM(fn_loan_fine(loan_id, p_as_of)),
            0
        )
    FROM loans
    WHERE due_on < p_as_of
      AND (
          returned_on IS NULL
          OR returned_on > p_as_of
      )

    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;

END;
$$;


/* =====================================================
   STEP 16: CREATE TODAY'S OVERDUE SUMMARY
   ===================================================== */

CALL pr_refresh_overdue(CURRENT_DATE);


/* =====================================================
   STEP 17: SCHEDULE THE DAILY JOB
   Runs daily at 00:10 for CURRENT_DATE.
   Requires pg_cron to be installed and configured.
   ===================================================== */

DO $$
DECLARE
    v_job_id BIGINT;
BEGIN
    BEGIN
        EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE
            'pg_cron could not be enabled: %',
            SQLERRM;
    END;

    IF to_regclass('cron.job') IS NOT NULL THEN

        FOR v_job_id IN
            EXECUTE
                'SELECT jobid FROM cron.job WHERE jobname = $1'
            USING 'library-daily-overdue-refresh'
        LOOP
            EXECUTE 'SELECT cron.unschedule($1)'
            USING v_job_id;
        END LOOP;

        EXECUTE
            'SELECT cron.schedule($1, $2, $3)'
        INTO v_job_id
        USING
            'library-daily-overdue-refresh',
            '10 0 * * *',
            'CALL pr_refresh_overdue(CURRENT_DATE);';

        RAISE NOTICE
            'Daily overdue summary job scheduled. Job ID: %',
            v_job_id;

    ELSE
        RAISE NOTICE
            'pg_cron is not available. The scheduled job needs server configuration.';
    END IF;
END;
$$;


/* =====================================================
   STEP 18: TEST THE FINE FUNCTION
   ===================================================== */

SELECT
    loan_id,
    borrower_name,
    fn_loan_fine(loan_id, CURRENT_DATE) AS calculated_fine
FROM loans
ORDER BY loan_id;


/* =====================================================
   STEP 19: DISPLAY ALL BOOKS
   ===================================================== */

SELECT *
FROM books
ORDER BY book_id;


/* =====================================================
   STEP 20: DISPLAY ALL LOANS
   ===================================================== */

SELECT *
FROM loans
ORDER BY loan_id;


/* =====================================================
   STEP 21: DISPLAY THE LOAN AUDIT TABLE
   ===================================================== */

SELECT *
FROM loan_audit
ORDER BY audit_id;


/* =====================================================
   STEP 22: DISPLAY THE OVERDUE LOANS VIEW
   ===================================================== */

SELECT *
FROM v_overdue_loans
ORDER BY due_on;


/* =====================================================
   STEP 23: DISPLAY THE OVERDUE SUMMARY
   ===================================================== */

SELECT *
FROM overdue_summary
ORDER BY snapshot_date;


/* =====================================================
   STEP 24: SHOW THE EXPLAIN PLAN FOR THE INDEX QUERY
   ===================================================== */

EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
AND returned_on IS NULL;


/* =====================================================
   END OF QUESTION 3
   ===================================================== */
