using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class ModifySmartschoolData : GroupAction
    {
        public enum Fields
        {
            Instellingsnummer,
            UntisID,
            Beschrijving,
            AdministratiefNummer,
        }

        public List<Fields> List = new List<Fields>();

        public new string Description
        {
            get
            {
                string result = "De volgende velden zijn niet up to date in smartschool: ";
                foreach(var field in List)
                {
                    result += field.ToString() + ", ";
                }
                result = result.Remove(result.Count() - 2, 2);
                result += ". Ze kunnen automatisch aangepast worden.";
                return result;
            }
        }

        public ModifySmartschoolData() : base(
            "Wijzig de Smartschool Groep",
            "...",
            true)
        {

        }

        public override async Task Apply(LinkedGroup linkedGroup)
        {
            InProgress.Value = true;
            foreach(var field in List)
            {
                switch(field)
                {
                    case Fields.Instellingsnummer: linkedGroup.smartschoolGroup.InstituteNumber = linkedGroup.wisaGroup.SchoolCode;
                        break;
                    case Fields.UntisID: linkedGroup.smartschoolGroup.Untis = linkedGroup.smartschoolGroup.Name;
                        break;
                    case Fields.Beschrijving: linkedGroup.smartschoolGroup.Description = linkedGroup.wisaGroup.Description;
                        break;
                    case Fields.AdministratiefNummer: linkedGroup.smartschoolGroup.AdminNumber = Convert.ToInt32(linkedGroup.wisaGroup.AdminCode);
                        break;
                }
            }
            await AccountApi.Smartschool.GroupManager.Save(linkedGroup.smartschoolGroup);
            InProgress.Value = false;
        }
    }
}
