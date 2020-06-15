using System;
using System.Threading.Tasks;
using System.Windows.Media.Animation;

namespace AccountManager.Action.Group
{
    class AddToSmartschool : GroupAction
    {
        public override async Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            var wisa = linkedGroup.Wisa.Group;
            var parentName = AccountApi.Smartschool.GroupManager.GetLogicalParent(wisa.Name);
            var parent = (AccountApi.Smartschool.GroupManager.Root as AccountApi.Smartschool.Group).FindByCode(parentName);

            if (parent != null)
            {
                var group = new AccountApi.Smartschool.Group(parent);
                group.Name = wisa.Name;
                group.Description = wisa.Description;
                group.Code = wisa.Name;
                group.Untis = wisa.Name;
                group.InstituteNumber = wisa.SchoolCode;
                group.AdminNumber = int.Parse(wisa.AdminCode);
                group.Official = true;
                group.Type = AccountApi.GroupType.Class;

                bool result = await AccountApi.Smartschool.GroupManager.Save(group).ConfigureAwait(false);
                if (result) parent.Children.Add(group);
            }
        }

        public AddToSmartschool() : base(
            "Klas toevoegen aan Smartschool",
            "Voeg deze klas toe aan Smartschool.",
            true)
        {
        }

        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Wisa.Linked && !group.Smartschool.Linked && group.Wisa.Group.ContainsStudents())
            {
                group.Actions.Add(new AddToSmartschool());
                return true;
            }
            return false;
        }
    }
}
