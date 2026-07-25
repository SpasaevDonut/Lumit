use flutter_rust_bridge::frb;
use uuid::Uuid;

#[derive(Debug, PartialEq, Eq)]
#[frb]
pub struct FolderReference {
    #[frb(name = "internalproject")]
    pub project: Uuid,
    #[frb(name = "internalid")]
    pub id: Uuid,
}

impl FolderReference {

    #[frb(ignore)]
    pub fn new(project: Uuid, id: Uuid) -> FolderReference {
        FolderReference { project, id }
    }

    #[frb(ignore)]
    pub fn project_id(&self) -> Uuid{
        self.project
    }

    #[frb(ignore)]
    pub fn id(&self) -> Uuid {
        self.id
    }
}