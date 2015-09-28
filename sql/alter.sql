alter table users ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table salts ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table relations ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table profiles ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table footprints ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table entries ENGINE=InnoDB ROW_FORMAT=COMPRESSED;

ALTER TABLE comments 
ADD to_user_id int(11) NOT NULL,
ADD KEY `user_id` (`user_id`),
ADD KEY `to_user_id` (`to_user_id`),
ROW_FORMAT=COMPRESSED
;

UPDATE comments c
 INNER JOIN entries e ON (c.entry_id = e.id)
 SET c.to_user_id = e.user_id;

CREATE TABLE IF NOT EXISTS footprint_fasts (
  `user_id` int NOT NULL,
  `print_date` DATE NOT NULL,
  `owner_id` int NOT NULL,
  `print_datetime` DATETIME NOT NULL,
  PRIMARY KEY (`user_id`, `print_date`, `owner_id`),
  KEY (`print_date`)
) DEFAULT CHARSET=utf8  ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
insert into footprint_fasts select user_id, DATE(created_at), owner_id, created_at from footprints group by owner_id, DATE(created_at);

