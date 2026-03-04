'use strict';
require('./tracing');

const express = require('express');

const app = express();

const flights = [
  { id: 'f1',  airline: 'Air France',    flightNumber: 'AF007', from: 'New York', to: 'Paris',    departure: '10:00', arrival: '22:00', durationHours: 8,    price: 650, available: true  },
  { id: 'f2',  airline: 'Delta Airlines', flightNumber: 'DL402', from: 'New York', to: 'Paris',    departure: '22:30', arrival: '10:30', durationHours: 8,    price: 580, available: true  },
  { id: 'f3',  airline: 'British Airways',flightNumber: 'BA112', from: 'New York', to: 'London',   departure: '19:00', arrival: '07:00', durationHours: 7,    price: 520, available: true  },
  { id: 'f4',  airline: 'Japan Airlines', flightNumber: 'JL003', from: 'New York', to: 'Tokyo',    departure: '14:00', arrival: '17:00', durationHours: 14,   price: 890, available: true  },
  { id: 'f5',  airline: 'Air France',     flightNumber: 'AF008', from: 'Paris',    to: 'New York', departure: '11:00', arrival: '13:00', durationHours: 8,    price: 620, available: true  },
  { id: 'f6',  airline: 'British Airways',flightNumber: 'BA175', from: 'London',   to: 'New York', departure: '09:00', arrival: '12:00', durationHours: 7,    price: 490, available: true  },
  { id: 'f7',  airline: 'Eurostar',       flightNumber: 'EU215', from: 'Paris',    to: 'London',   departure: '08:00', arrival: '09:20', durationHours: 1.5,  price: 180, available: true  },
  { id: 'f8',  airline: 'ANA',            flightNumber: 'NH010', from: 'Tokyo',    to: 'New York', departure: '11:30', arrival: '10:30', durationHours: 12,   price: 780, available: true  },
  { id: 'f9',  airline: 'Japan Airlines', flightNumber: 'JL406', from: 'Tokyo',    to: 'Paris',    departure: '09:00', arrival: '16:00', durationHours: 12,   price: 820, available: false },
  { id: 'f10', airline: 'British Airways',flightNumber: 'BA006', from: 'London',   to: 'Tokyo',    departure: '12:00', arrival: '09:00', durationHours: 11,   price: 750, available: true  },
];

app.get('/health', (_, res) => res.json({ status: 'ok' }));

app.get('/flights', (req, res) => {
  const { from, to } = req.query;
  let results = flights;
  if (from) results = results.filter(f => f.from.toLowerCase() === from.toLowerCase());
  if (to)   results = results.filter(f => f.to.toLowerCase()   === to.toLowerCase());
  console.log(JSON.stringify({ level: 'info', msg: 'flights.search', from, to, count: results.length }));
  res.json(results);
});

app.get('/flights/:id', (req, res) => {
  const flight = flights.find(f => f.id === req.params.id);
  if (!flight) return res.status(404).json({ error: 'Flight not found' });
  res.json(flight);
});

app.listen(3002, () =>
  console.log(JSON.stringify({ level: 'info', msg: 'flight-service started', port: 3002 }))
);
