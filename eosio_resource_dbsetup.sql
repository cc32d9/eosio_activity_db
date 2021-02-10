CREATE DATABASE eosio_resource;

CREATE USER 'eosio_resource'@'localhost' IDENTIFIED BY 'tau9Oixe';
GRANT ALL ON eosio_resource.* TO 'eosio_resource'@'localhost';
grant SELECT on eosio_resource.* to 'eosio_resource_ro'@'%' identified by 'eosio_resource_ro';

use eosio_resource;

CREATE TABLE SYNC
(
 network           VARCHAR(15) PRIMARY KEY,
 block_num         BIGINT NOT NULL
) ENGINE=InnoDB;


CREATE TABLE POWERUP
(
 network       VARCHAR(15) NOT NULL,
 seq           BIGINT UNSIGNED NOT NULL,
 block_num     BIGINT UNSIGNED NOT NULL,
 block_time    DATETIME NOT NULL,
 trx_id        VARCHAR(64) NOT NULL,
 payer         VARCHAR(13) NOT NULL,
 receiver      VARCHAR(13) NOT NULL,
 ndays         INT UNSIGNED NOT NULL,
 net_frac      BIGINT UNSIGNED NOT NULL,
 cpu_frac      BIGINT UNSIGNED NOT NULL,
 max_payment   DOUBLE PRECISION NOT NULL,
 fee           DOUBLE PRECISION NOT NULL,
 powup_net     BIGINT UNSIGNED NOT NULL,
 powup_cpu     BIGINT UNSIGNED NOT NULL
)  ENGINE=InnoDB;

CREATE UNIQUE INDEX POWERUP_I01 ON POWERUP (network, seq);
CREATE INDEX POWERUP_I02 ON POWERUP (network, block_time);
CREATE INDEX POWERUP_I03 ON POWERUP (network, payer, block_time);
CREATE INDEX POWERUP_I04 ON POWERUP (network, receiver, block_time);


