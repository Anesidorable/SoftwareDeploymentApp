FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

RUN npx prisma contract emit

USER node
EXPOSE 5000
CMD ["sh", "-c", "npx prisma db migrate && node index.js"]