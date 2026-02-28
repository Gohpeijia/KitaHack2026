/* eslint-disable no-undef */
importScripts('https://www.gstatic.com/firebasejs/10.13.2/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.13.2/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyDrX3gfGBvrTxHTwq7d2uAsa-Qu5ZDnnd4',
  appId: '1:302420738156:web:64e8a15b9b3d66cd5a9849',
  messagingSenderId: '302420738156',
  projectId: 'kitahack2026-c2a42',
  authDomain: 'kitahack2026-c2a42.firebaseapp.com',
  storageBucket: 'kitahack2026-c2a42.firebasestorage.app',
  measurementId: 'G-K91CD1ND7Z',
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  const title = payload?.notification?.title || 'Expiry reminder';
  const body = payload?.notification?.body || 'You have items near expiry.';

  self.registration.showNotification(title, {
    body,
    icon: '/icons/Icon-192.png',
    data: payload?.data || {},
  });
});
