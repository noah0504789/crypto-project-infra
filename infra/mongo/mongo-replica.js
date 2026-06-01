// docker-entrypoint-initdb.d/init-replica.js
db = db.getSiblingDB("admin");

// 안전하게 election 전에 구성되도록 sleep (bash 따로 써도 됨)
sleep(10000);

db.auth("root", "rootpass")

rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo-primary:27017", priority: 2 },
    { _id: 1, host: "mongo-secondary-0:27017", priority: 1 },
    { _id: 2, host: "mongo-secondary-1:27017", priority: 1 }
  ]
});
