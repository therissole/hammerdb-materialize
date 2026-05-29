select
	od.o_id,
	od.o_w_id,
	od.o_d_id,
	od.o_c_id,
	od.o_ol_cnt,
	od.o_entry_d,
	wa.w_id,
	wa.w_name,
	cu.c_first,
	cu.c_last,
	cu.c_state,
	cu.c_street_1,
	cu.c_street_2,
	cu.c_phone,
	(select sum(ol.ol_amount) from order_line ol where ol.ol_o_id = od.o_id and ol.ol_d_id = od.o_d_id and ol.ol_w_id = od.o_w_id) as o_total
from
	orders od inner join customer cu on od.o_c_id = cu.c_id and od.o_d_id = cu.c_d_id and od.o_w_id = cu.c_w_id
	join warehouse wa on od.o_w_id = wa.w_id


