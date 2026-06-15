FROM node:22-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends sqlite3 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
COPY server.mjs ./
COPY public ./public

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=4173
ENV QUIZLOOP_DB_PATH=/data/quizloop.sqlite

RUN mkdir -p /data

EXPOSE 4173

CMD ["npm", "start"]
