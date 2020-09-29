using AbstractAccountApi;
using AccountManager.State.Linked;
using AccountManager.Utils;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Documents;

namespace AccountManager.Action.Group
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
                foreach (var field in List)
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
            CanShowDetails = true;
        }

        public override async Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            InProgress.Value = true;
            foreach (var field in List)
            {
                switch (field)
                {
                    case Fields.Instellingsnummer:
                        linkedGroup.Smartschool.Group.InstituteNumber = linkedGroup.Wisa.Group.SchoolCode;
                        break;
                    case Fields.UntisID:
                        linkedGroup.Smartschool.Group.Untis = linkedGroup.Smartschool.Group.Name;
                        break;
                    case Fields.Beschrijving:
                        linkedGroup.Smartschool.Group.Description = linkedGroup.Wisa.Group.Description;
                        break;
                    case Fields.AdministratiefNummer:
                        linkedGroup.Smartschool.Group.AdminNumber = Convert.ToInt32(linkedGroup.Wisa.Group.AdminCode);
                        break;
                }
            }
            await AccountApi.Smartschool.GroupManager.Save(linkedGroup.Smartschool.Group).ConfigureAwait(false);
            InProgress.Value = false;
        }

        public override FlowDocument GetDetails(LinkedGroup group)
        {
            var result = new FlowTableCreator(true);
            result.SetHeaders(new string[] { "Wisa", "Smartschool" });

            result.AddRow(new List<string>() { "Instituut", group.Wisa.Group.SchoolCode, group.Smartschool.Group.InstituteNumber });
            result.AddRow(new List<string>() { "Untis Code", group.Smartschool.Group.Name, group.Smartschool.Group.Untis });
            result.AddRow(new List<string>() { "Beschrijving", group.Wisa.Group.Description, group.Smartschool.Group.Description });

            FlowDocument document = new FlowDocument();
            document.Blocks.Add(result.Create());

            return document;
        }

        public static void Evaluate(State.Linked.LinkedGroup group)
        {
            var action = new ModifySmartschoolData();

            if (group.Wisa.Group.SchoolCode != group.Smartschool.Group.InstituteNumber) 
                action.List.Add(ModifySmartschoolData.Fields.Instellingsnummer);
            if (group.Smartschool.Group.Name != group.Smartschool.Group.Untis) 
                action.List.Add(ModifySmartschoolData.Fields.UntisID);
            if (group.Smartschool.Group.Description != group.Wisa.Group.Description) 
                action.List.Add(ModifySmartschoolData.Fields.Beschrijving);

            if(action.List.Count > 0)
            {
                group.Actions.Add(action);
                group.Smartschool.FlagWarning();
            }
        }
    }
}
