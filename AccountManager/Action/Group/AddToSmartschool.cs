using System;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    class AddToSmartschool : GroupAction
    {
        public override Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
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
