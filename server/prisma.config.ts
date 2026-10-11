import dotenv from 'dotenv';
import { definePrismaConfig } from 'prisma/config';
import { defineConfig as ormConfig } from '@prisma/orm-postgres/config';


//Use the root .env file
dotenv.config({ path: '../.env' });

const { DB_USER, DB_PASSWORD, DB_NAME, DB_HOST = 'localhost', DB_PORT = '5432' } = process.env;

const connection =
  process.env.DATABASE_URL ??
  `postgresql://${DB_USER}:${encodeURIComponent(DB_PASSWORD ?? '')}@${DB_HOST}:${DB_PORT}/${DB_NAME}`;


export default definePrismaConfig({
  orm: ormConfig({
    contract: "./prisma/schema.prisma",
    output: 'generated/prisma8',
    db: {connection},
  }),
});
