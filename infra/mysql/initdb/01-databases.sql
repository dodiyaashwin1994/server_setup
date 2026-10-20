-- Databases of the two services. Each account's own database (lease_<subdomain>) is created by the lease service when the account is onboarded.
CREATE DATABASE IF NOT EXISTS `auth` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS `lease_default` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
