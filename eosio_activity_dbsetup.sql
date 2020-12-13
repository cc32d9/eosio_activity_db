CREATE DATABASE eosio_activity;

CREATE USER 'eosio_activity'@'localhost' IDENTIFIED BY 'De3PhooL';
GRANT ALL ON eosio_activity.* TO 'eosio_activity'@'localhost';
grant SELECT on eosio_activity.* to 'eosio_activity_ro'@'%' identified by 'eosio_activity_ro';

use eosio_activity;

CREATE TABLE SYNC
(
 network           VARCHAR(15) PRIMARY KEY,
 block_num         BIGINT NOT NULL
) ENGINE=InnoDB;


