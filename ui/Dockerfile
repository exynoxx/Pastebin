FROM node:18

WORKDIR /app

# Copy package.json and package-lock.json to leverage caching
COPY ui/package*.json ./

RUN npm install

COPY ui/ .

WORKDIR /app/ui
EXPOSE 8080

CMD ["npm", "run", "serve"]
