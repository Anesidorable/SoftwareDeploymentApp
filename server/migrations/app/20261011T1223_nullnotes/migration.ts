#!/usr/bin/env -S node
import type { Contract as Start } from '../../snapshots/074c26e608ff8caa6b33818a6d6cafaaf8c486642c2db3c858018ffb8b2c22ad/contract';
import startContract from '../../snapshots/074c26e608ff8caa6b33818a6d6cafaaf8c486642c2db3c858018ffb8b2c22ad/contract.json' with { type: 'json' };
import type { Contract as End } from '../../snapshots/d25a92cc1958dcde13efcee29deb1474c9e15689a573555d9ec032e6a11bd75b/contract';
import endContract from '../../snapshots/d25a92cc1958dcde13efcee29deb1474c9e15689a573555d9ec032e6a11bd75b/contract.json' with { type: 'json' };
import { Migration, MigrationCLI } from '@prisma/orm-postgres/migration';

export default class M extends Migration<Start, End> {
  override readonly startContractJson = startContract;
  override readonly endContractJson = endContract;

  override get operations() {
    return [this.dropNotNull({ schema: 'public', table: 'GroceryList', column: 'notes' })];
  }
}

MigrationCLI.run(import.meta.url, M);
