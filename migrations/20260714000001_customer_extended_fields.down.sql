ALTER TABLE customers
    DROP COLUMN IF EXISTS short_name,
    DROP COLUMN IF EXISTS customer_type,
    DROP COLUMN IF EXISTS company_size,
    DROP COLUMN IF EXISTS source,
    DROP COLUMN IF EXISTS level,
    DROP COLUMN IF EXISTS region_province,
    DROP COLUMN IF EXISTS region_city,
    DROP COLUMN IF EXISTS region_district,
    DROP COLUMN IF EXISTS address,
    DROP COLUMN IF EXISTS phone,
    DROP COLUMN IF EXISTS email,
    DROP COLUMN IF EXISTS contacts;
