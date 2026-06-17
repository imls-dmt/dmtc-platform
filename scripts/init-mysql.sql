-- Initial schema for the DMTC API.
-- Matches the Flask-SQLAlchemy models in dmtclearinghouse.py.
-- MySQL runs this automatically on first container start via
-- /docker-entrypoint-initdb.d/.

CREATE TABLE IF NOT EXISTS learningresources (
    id   VARCHAR(36)  NOT NULL,
    value MEDIUMTEXT  NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS taxonomies (
    id   VARCHAR(36)  NOT NULL,
    value MEDIUMTEXT  NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS users (
    id   VARCHAR(36)  NOT NULL,
    value MEDIUMTEXT  NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS feedback (
    id   VARCHAR(36)  NOT NULL,
    value MEDIUMTEXT  NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS tokens (
    id    INT          NOT NULL AUTO_INCREMENT,
    token TEXT,
    date  DATETIME,
    uuid  VARCHAR(40),
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
