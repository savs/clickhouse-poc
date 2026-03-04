'use strict';
require('./tracing');

const express = require('express');
const { ApolloServer } = require('@apollo/server');
const { expressMiddleware } = require('@apollo/server/express4');
const cors = require('cors');
const axios = require('axios');

const HOTEL_URL   = process.env.HOTEL_SERVICE_URL   || 'http://hotel-service:3001';
const FLIGHT_URL  = process.env.FLIGHT_SERVICE_URL  || 'http://flight-service:3002';

const typeDefs = `#graphql
  type Hotel {
    id: ID!
    name: String!
    location: String!
    pricePerNight: Float!
    rating: Float!
    available: Boolean!
  }

  type Flight {
    id: ID!
    airline: String!
    flightNumber: String!
    from: String!
    to: String!
    departure: String!
    arrival: String!
    durationHours: Float!
    price: Float!
    available: Boolean!
  }

  type Booking {
    id: ID!
    hotel: Hotel
    flight: Flight
    totalPrice: Float!
    status: String!
  }

  type Query {
    hotels(location: String): [Hotel!]!
    hotel(id: ID!): Hotel
    flights(from: String!, to: String!): [Flight!]!
    flight(id: ID!): Flight
  }

  type Mutation {
    bookTrip(hotelId: ID, flightId: ID): Booking!
  }
`;

const resolvers = {
  Query: {
    hotels: async (_, { location }) => {
      const qs = location ? `?location=${encodeURIComponent(location)}` : '';
      const { data } = await axios.get(`${HOTEL_URL}/hotels${qs}`);
      return data;
    },
    hotel: async (_, { id }) => {
      const { data } = await axios.get(`${HOTEL_URL}/hotels/${id}`);
      return data;
    },
    flights: async (_, { from, to }) => {
      const { data } = await axios.get(
        `${FLIGHT_URL}/flights?from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`
      );
      return data;
    },
    flight: async (_, { id }) => {
      const { data } = await axios.get(`${FLIGHT_URL}/flights/${id}`);
      return data;
    },
  },
  Mutation: {
    bookTrip: async (_, { hotelId, flightId }) => {
      let hotel = null, flight = null;
      if (hotelId) {
        const { data } = await axios.get(`${HOTEL_URL}/hotels/${hotelId}`);
        hotel = data;
      }
      if (flightId) {
        const { data } = await axios.get(`${FLIGHT_URL}/flights/${flightId}`);
        flight = data;
      }
      const totalPrice = (hotel?.pricePerNight ?? 0) + (flight?.price ?? 0);
      const id = `BK-${Date.now().toString(36).toUpperCase()}`;
      console.log(JSON.stringify({ level: 'info', msg: 'booking.created', id, hotelId, flightId, totalPrice }));
      return { id, hotel, flight, totalPrice, status: 'CONFIRMED' };
    },
  },
};

async function start() {
  const app = express();
  const server = new ApolloServer({ typeDefs, resolvers });

  await server.start();

  app.get('/health', (_, res) => res.json({ status: 'ok' }));
  app.use('/graphql', cors(), express.json(), expressMiddleware(server));

  app.listen(4000, () =>
    console.log(JSON.stringify({ level: 'info', msg: 'booking-service started', port: 4000 }))
  );
}

start().catch(err => { console.error(err); process.exit(1); });
