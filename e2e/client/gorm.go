package main

import (
	"context"
	"database/sql"
	"errors"

	"github.com/jackc/pgx/v5/stdlib"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// gormPool is GORM with its own pgx pool on the rw port of the hosts, as an
// application without pgfallback has it: target_session_attrs=read-write
// and the connection string's connect_timeout, nothing more.
type gormPool struct{ db *gorm.DB }

// openGORM opens the pool without connecting: ensureTable makes the first
// connection, and tries again until it works.
func openGORM(hosts []string, _ string) (pool, error) {
	db, err := gorm.Open(postgres.Open(dsn(hosts)+" target_session_attrs=read-write"),
		&gorm.Config{DisableAutomaticPing: true, Logger: logger.Discard})
	if err != nil {
		return nil, err
	}
	sqlDB, err := db.DB()
	if err != nil {
		return nil, err
	}
	sqlDB.SetMaxOpenConns(maxConns)
	return gormPool{db}, nil
}

func (p gormPool) exec(ctx context.Context, query string) error {
	return p.db.WithContext(ctx).Exec(query).Error
}

// row runs the statement on one connection of GORM's pool.
func (p gormPool) row(ctx context.Context, query string, args map[string]any, dest ...any) (string, error) {
	addr := "-"
	err := p.db.WithContext(ctx).Connection(func(tx *gorm.DB) error {
		var err error
		if addr, err = connAddress(tx); err != nil {
			return err
		}
		var named []any
		if args != nil {
			named = append(named, args)
		}
		rows, err := tx.Raw(query, named...).Rows()
		if err != nil {
			return err
		}
		return scanOne(rows, dest...)
	})
	return addr, err
}

// scanOne scans the one row of rows into dest. The statement has ended, its
// commit included, once the rows are closed. Rows that database/sql closed
// when the context ended give that error only from Err, so scanOne checks
// it after Close.
func scanOne(rows *sql.Rows, dest ...any) (err error) {
	defer func() {
		err = errors.Join(err, rows.Close())
		if err == nil {
			err = rows.Err()
		}
	}()
	if !rows.Next() {
		if err := rows.Err(); err != nil {
			return err
		}
		return sql.ErrNoRows
	}
	return rows.Scan(dest...)
}

func (p gormPool) close() {
	sqlDB, err := p.db.DB()
	if err == nil {
		err = sqlDB.Close()
	}
	if err != nil {
		warn("client: closing the pool: %v", err)
	}
}

// connAddress is the <host>:<port> of the connection GORM's Connection
// holds.
func connAddress(tx *gorm.DB) (string, error) {
	conn, ok := tx.Statement.ConnPool.(*sql.Conn)
	if !ok {
		return "-", errors.New("GORM's Connection holds no *sql.Conn")
	}
	addr := "-"
	err := conn.Raw(func(driverConn any) error {
		c, ok := driverConn.(*stdlib.Conn)
		if !ok {
			return errors.New("the connection is not pgx's")
		}
		addr = address(c.Conn().PgConn())
		return nil
	})
	return addr, err
}
