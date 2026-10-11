import dotenv from "dotenv";
import postgres from "@prisma/orm-postgres/runtime";
import contractJson from "./generated/prisma8/contract.json" with { type: "json" };

// Root env file
dotenv.config({ path: "../.env" });

const { DB_USER, DB_PASSWORD, DB_NAME, DB_HOST = "localhost", DB_PORT = "5432" } = process.env;

// Creates URL dependant on if the env variables are set. Diffrentiates between localhost and docker.
const url =
  process.env.DATABASE_URL ??
  `postgresql://${DB_USER}:${encodeURIComponent(DB_PASSWORD ?? "")}@${DB_HOST}:${DB_PORT}/${DB_NAME}`;

export const db = postgres({ url, contractJson });