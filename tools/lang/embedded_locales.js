'use strict';

// Shared by embed.js and sign_shipped.js so they cannot disagree.
// 'uk' is deliberately absent: its catalog is pure identity, so it indexes
// nothing and sign.js refuses it; the menu pins Ukrainian from a constant.
module.exports = { EMBEDDED: ['en', 'bg'] };
