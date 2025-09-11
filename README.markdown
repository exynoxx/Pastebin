# Pastebin Application

This project is a full-stack Pastebin application consisting of a backend API (`pastebin-api`) built with .NET 8.0 and a frontend UI (`pastebin-frontend`) built with React. The application allows users to create, store, and share text snippets. Both services are containerized using Docker and orchestrated with Docker Compose.

## Author
Claude AI

## Project Structure

```
pastebin/
├── pastebin-api/
│   ├── Dockerfile
│   ├── pastebin.api.csproj
│   ├── Program.cs
│   └── ...
├── pastebin-frontend/
│   ├── Dockerfile
│   ├── package.json
│   ├── src/
│   └── ...
├── docker-compose.yml
└── README.md
```

- **pastebin-api**: A .NET 8.0 API serving as the backend, exposing endpoints for managing text snippets.
- **pastebin-frontend**: A React frontend for interacting with the API, built with `react-scripts`.
- **docker-compose.yml**: Orchestrates the API and UI services, connecting them via a Docker network.

## Running

1. **Clone the Repository**:
   ```bash
   git clone <repository-url>
   cd pastebin
   docker compose up
   ```

   2. **Access the Application**:
   - **Frontend**: Open `http://localhost:3000` in your browser to access the React UI.
   - **API**: Test the API at `http://localhost:8080` (e.g., using `curl` or Postman).

3. **Stop the Services**:
   To stop the containers, press `Ctrl+C` or run:
   ```bash
   docker-compose down
   ```

## Security Notes

- The current CORS policy (`AllowAll`) allows requests from any origin, which is insecure for production. Update `Program.cs` to specify allowed origins (e.g., `http://localhost:3000` or your production domain).
- Consider adding authentication and HTTPS for production deployments.
