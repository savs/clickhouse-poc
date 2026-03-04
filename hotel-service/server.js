'use strict';
require('./tracing');

const express = require('express');

const app = express();

const hotels = [
  { id: 'h1', name: 'Hotel Lumière',         location: 'Paris',    pricePerNight: 189, rating: 4.5, available: true  },
  { id: 'h2', name: 'Le Grand Palais Hôtel', location: 'Paris',    pricePerNight: 320, rating: 4.8, available: true  },
  { id: 'h3', name: 'NYC Times Square Inn',  location: 'New York', pricePerNight: 220, rating: 4.2, available: true  },
  { id: 'h4', name: 'The Manhattan',         location: 'New York', pricePerNight: 450, rating: 4.9, available: true  },
  { id: 'h5', name: 'Tokyo Shibuya Hotel',   location: 'Tokyo',    pricePerNight: 160, rating: 4.6, available: true  },
  { id: 'h6', name: 'Park Hyatt Tokyo',      location: 'Tokyo',    pricePerNight: 560, rating: 4.9, available: false },
  { id: 'h7', name: 'The Savoy',             location: 'London',   pricePerNight: 380, rating: 4.8, available: true  },
  { id: 'h8', name: 'Premier Inn Waterloo',  location: 'London',   pricePerNight: 140, rating: 4.1, available: true  },
];

app.get('/health', (_, res) => res.json({ status: 'ok' }));

app.get('/hotels', (req, res) => {
  const { location } = req.query;
  const results = location
    ? hotels.filter(h => h.location.toLowerCase().includes(location.toLowerCase()))
    : hotels;
  console.log(JSON.stringify({ level: 'info', msg: 'hotels.search', location: location || 'all', count: results.length }));
  res.json(results);
});

app.get('/hotels/:id', (req, res) => {
  const hotel = hotels.find(h => h.id === req.params.id);
  if (!hotel) return res.status(404).json({ error: 'Hotel not found' });
  res.json(hotel);
});

app.listen(3001, () =>
  console.log(JSON.stringify({ level: 'info', msg: 'hotel-service started', port: 3001 }))
);
