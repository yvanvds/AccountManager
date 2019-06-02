using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class ModifySmartschoolData : IAction
    {
        public enum Fields
        {
            Instellingsnummer,
            UntisID,
            Beschrijving,
            AdministratiefNummer,
        }

        public List<Fields> List = new List<Fields>();

        public string Header => "Wijzig de Smartschool Groep";

        public string Description
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
 
        public bool CanBeApplied => true;

        public ObservableProperties.Prop<bool> InProgress { get; set; } = new ObservableProperties.Prop<bool>() { Value = false };

        public async Task Apply(LinkedGroup linkedGroup)
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
            await SmartschoolApi.GroupManager.Save(linkedGroup.smartschoolGroup);
            InProgress.Value = false;
        }
    }
}
