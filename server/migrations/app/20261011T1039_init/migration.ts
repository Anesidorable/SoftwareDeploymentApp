#!/usr/bin/env -S node
import type { Contract as End } from '../../snapshots/074c26e608ff8caa6b33818a6d6cafaaf8c486642c2db3c858018ffb8b2c22ad/contract';
import endContract from '../../snapshots/074c26e608ff8caa6b33818a6d6cafaaf8c486642c2db3c858018ffb8b2c22ad/contract.json' with { type: 'json' };
import { Migration, MigrationCLI, col, lit, primaryKey } from '@prisma/orm-postgres/migration';

export default class M extends Migration<never, End> {
  override readonly endContractJson = endContract;

  override get operations() {
    return [
      this.createSchema({ schema: 'public' }),
      this.createTable({
        schema: 'public',
        table: 'GroceryList',
        columns: [
          col('count', 'float8', { notNull: true, codecRef: { codecId: 'pg/float8@1' } }),
          col('id', 'SERIAL', { notNull: true, codecRef: { codecId: 'pg/int4@1' } }),
          col('item', 'text', { notNull: true, codecRef: { codecId: 'pg/text@1' } }),
          col('notes', 'text', { notNull: true, codecRef: { codecId: 'pg/text@1' } }),
          col('ticked', 'bool', {
            notNull: true,
            default: lit(false),
            codecRef: { codecId: 'pg/bool@1' },
          }),
        ],
        constraints: [primaryKey(['id'])],
      }),
    ];
  }
}

MigrationCLI.run(import.meta.url, M);
