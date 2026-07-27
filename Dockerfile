FROM node:24-alpine AS runtime

ENV NODE_ENV=production
ENV PORT=3000

WORKDIR /app

# A committed lockfile makes the image and npm audit reproducible.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY --chown=node:node src ./src

USER node

EXPOSE 3000

# Run Node directly so npm does not need a writable cache at runtime.
CMD ["node", "src/health.js"]
