--------------------------------------------------------------------------------
-- 01_seed_departments_providers.sql
--
-- Small reference datasets: departments and providers. Hand-written (not
-- generated) because they are low-cardinality, named entities that should
-- read naturally in report output.
--------------------------------------------------------------------------------

INSERT INTO departments (department_name, location, phone) VALUES ('Cardiology',        'Building A, Floor 3', '555-0101');
INSERT INTO departments (department_name, location, phone) VALUES ('Family Medicine',    'Building A, Floor 1', '555-0102');
INSERT INTO departments (department_name, location, phone) VALUES ('Orthopedics',        'Building B, Floor 2', '555-0103');
INSERT INTO departments (department_name, location, phone) VALUES ('Pediatrics',         'Building A, Floor 2', '555-0104');
INSERT INTO departments (department_name, location, phone) VALUES ('Endocrinology',      'Building B, Floor 1', '555-0105');
INSERT INTO departments (department_name, location, phone) VALUES ('Laboratory Services', 'Building C, Floor 1', '555-0106');

-- department_id values below assume a clean load (IDs 1..6, in insert order).
-- If re-seeding onto an existing schema, re-check with:
--   SELECT department_id, department_name FROM departments ORDER BY department_id;

INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000001', 'Elena',   'Martinez',  'Cardiology',       1, 'e.martinez@clinic.example',  '555-0201', 'Y', DATE '2015-03-10');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000002', 'Rohan',   'Gupta',     'Cardiology',       1, 'r.gupta@clinic.example',     '555-0202', 'Y', DATE '2018-07-22');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000003', 'Sarah',   'Johnson',   'Family Medicine',  2, 's.johnson@clinic.example',   '555-0203', 'Y', DATE '2012-01-15');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000004', 'Michael', 'Chen',      'Family Medicine',  2, 'm.chen@clinic.example',      '555-0204', 'Y', DATE '2019-09-01');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000005', 'Amara',   'Okafor',    'Family Medicine',  2, 'a.okafor@clinic.example',    '555-0205', 'Y', DATE '2021-04-18');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000006', 'David',   'Kim',       'Orthopedics',      3, 'd.kim@clinic.example',       '555-0206', 'Y', DATE '2014-11-03');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000007', 'Priya',   'Nair',      'Orthopedics',      3, 'p.nair@clinic.example',      '555-0207', 'Y', DATE '2020-02-27');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000008', 'James',   'Walker',    'Pediatrics',       4, 'j.walker@clinic.example',    '555-0208', 'Y', DATE '2016-06-12');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000009', 'Linda',   'Park',      'Pediatrics',       4, 'l.park@clinic.example',      '555-0209', 'Y', DATE '2017-08-30');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000010', 'Omar',    'Haddad',    'Endocrinology',    5, 'o.haddad@clinic.example',    '555-0210', 'Y', DATE '2013-05-05');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000011', 'Grace',   'Thompson',  'Endocrinology',    5, 'g.thompson@clinic.example',  '555-0211', 'Y', DATE '2022-01-10');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000012', 'Hassan',  'Ali',       'Laboratory Services', 6, 'h.ali@clinic.example',    '555-0212', 'Y', DATE '2011-10-20');
INSERT INTO providers (npi_number, first_name, last_name, specialty, department_id, email, phone, is_active, hire_date) VALUES
    ('1000000013', 'Natalie', 'Brooks',    'Family Medicine',  2, 'n.brooks@clinic.example',    '555-0213', 'N', DATE '2010-03-01');
