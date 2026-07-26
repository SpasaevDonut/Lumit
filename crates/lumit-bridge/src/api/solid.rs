use uuid::Uuid;

use flutter_rust_bridge::frb;

#[derive(Debug, PartialEq, Eq)]
#[frb]
pub struct SolidReference {
    #[frb(name = "internalproject")]
    pub project: Uuid,
    #[frb(name = "internalid")]
    pub id: Uuid,
}

impl SolidReference {
    #[frb(ignore)]
    pub fn new(project: Uuid, id: Uuid) -> SolidReference {
        SolidReference { project, id }
    }

    #[frb(ignore)]
    pub fn project_id(&self) -> Uuid {
        self.project
    }

    #[frb(ignore)]
    pub fn id(&self) -> Uuid {
        self.id
    }
}
