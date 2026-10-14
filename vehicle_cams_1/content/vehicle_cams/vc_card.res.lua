function data()
	return {
		type = "react-plugin ::VehicleEowExtensionPoint",
		data = {
			filePath = "vehicle_cams_1::/vehicle_cams/vc_card.script@VcCardPlugin",
			condition = "::/gui/entity_window/vehicle/vehicle_eow.script@isPlayerOwned",
			order = 15,
		}
	}
end
