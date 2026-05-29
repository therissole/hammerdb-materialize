select
	ol.ol_o_id,
	ol.ol_d_id,
	ol.ol_w_id,
	ol.ol_number,
	ol.ol_i_id,
	i.i_name,
	i.i_price,
	ol.ol_delivery_d,
	ol.ol_amount,
	ol.ol_supply_w_id,
	w.w_name,
	w.w_state,
	ol.ol_quantity
from
	order_line ol
	join item i on ol.ol_i_id = i.i_id
	join warehouse w on ol.ol_supply_w_id = w.w_id