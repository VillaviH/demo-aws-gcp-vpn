-- Idempotente. Variables sqlcmd: DB, APP_USER, APP_PASSWORD
IF DB_ID('$(DB)') IS NULL
    CREATE DATABASE [$(DB)];
GO

USE [$(DB)];
GO

IF OBJECT_ID('dbo.merchants') IS NULL
CREATE TABLE dbo.merchants (
    merchant_id   NVARCHAR(64)  NOT NULL PRIMARY KEY,
    business_name NVARCHAR(200),
    contact_name  NVARCHAR(200),
    email         NVARCHAR(200),
    phone         NVARCHAR(50),
    city          NVARCHAR(100),
    category      NVARCHAR(100),
    status        NVARCHAR(30),
    credit_limit  DECIMAL(18,2),
    created_at    NVARCHAR(40)
);
GO

IF SUSER_ID('$(APP_USER)') IS NULL
    CREATE LOGIN [$(APP_USER)] WITH PASSWORD = '$(APP_PASSWORD)', CHECK_POLICY = OFF;
GO

IF USER_ID('$(APP_USER)') IS NULL
    CREATE USER [$(APP_USER)] FOR LOGIN [$(APP_USER)];
GO

ALTER ROLE db_datareader ADD MEMBER [$(APP_USER)];
ALTER ROLE db_datawriter ADD MEMBER [$(APP_USER)];
GO
